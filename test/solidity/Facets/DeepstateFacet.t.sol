// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {
    ContractCallNotAllowed,
    CumulativeSlippageTooHigh,
    InvalidAmount,
    InvalidCallData,
    InvalidReceiver,
    InvalidSendingToken,
    NoSwapDataProvided
} from "lifi/Errors/GenericErrors.sol";
import {DeepstateFacet} from "lifi/Facets/DeepstateFacet.sol";
import {IDeepstateV1} from "lifi/Interfaces/IDeepstateV1.sol";
import {ILiFi} from "lifi/Interfaces/ILiFi.sol";
import {DeepstateFeeOnTransferToken, DeepstateTestToken, MockDeepstateV1} from "../utils/MockDeepstateV1.sol";

contract DeepstateRejectingReceiver {
    receive() external payable {
        revert();
    }
}

contract TestDeepstateFacet is DeepstateFacet {
    constructor(IDeepstateV1 _deepstate) DeepstateFacet(_deepstate) {}

    receive() external payable {}
}

contract DeepstateFacetTest is Test, ILiFi {
    TestDeepstateFacet private facet;
    MockDeepstateV1 private deepstate;
    DeepstateTestToken private token0;
    DeepstateTestToken private token1;
    address payable private receiver = payable(address(0xBEEF));

    function setUp() public {
        deepstate = new MockDeepstateV1();
        facet = new TestDeepstateFacet(deepstate);
        token0 = new DeepstateTestToken("Token 0", "T0");
        token1 = new DeepstateTestToken("Token 1", "T1");
    }

    function testSwapsERC20AndRefundsUnspentInput() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);

        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(token0), address(token1), 100);

        vm.expectEmit(true, true, true, true, address(facet));
        emit LiFiGenericSwapCompleted(
            bytes32(uint256(1)), "integrator", "referrer", receiver, address(token0), address(token1), 60, 50
        );

        uint256 amountOut =
            facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 50, swapData);

        assertEq(amountOut, 50);
        assertEq(token0.balanceOf(receiver), 40);
        assertEq(token1.balanceOf(receiver), 50);
        assertEq(token0.allowance(address(facet), address(deepstate)), 0);
        assertTrue(deepstate.allNoRest());
    }

    function testSwapsNativeAndRefundsUnspentInput() public {
        token1.mint(address(deepstate), 50);
        deepstate.configure(address(0), address(token1), 60, 50);

        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(0), address(token1), 100);
        uint256 amountOut = facet.swapTokensViaDeepstate{value: 100}(
            bytes32(uint256(1)), "integrator", "referrer", receiver, 50, swapData
        );

        assertEq(amountOut, 50);
        assertEq(receiver.balance, 40);
        assertEq(token1.balanceOf(receiver), 50);
        assertTrue(deepstate.allNoRest());
    }

    function testRevert_NativeInputRejectsExcessValue() public {
        token1.mint(address(deepstate), 50);
        deepstate.configure(address(0), address(token1), 60, 50);

        vm.expectRevert(InvalidAmount.selector);

        facet.swapTokensViaDeepstate{value: 101}(
            bytes32(uint256(1)), "integrator", "referrer", receiver, 50, _swapData(address(0), address(token1), 100)
        );
    }

    function testRevert_FeeOnTransferInputIsRejected() public {
        DeepstateFeeOnTransferToken feeToken = new DeepstateFeeOnTransferToken("Fee Token", "FEE");
        feeToken.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        feeToken.approve(address(facet), 100);
        deepstate.configure(address(feeToken), address(token1), 60, 50);

        vm.expectRevert(abi.encodeWithSelector(DeepstateFacet.NonStandardToken.selector, address(feeToken)));

        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            receiver,
            0,
            _swapData(address(feeToken), address(token1), 100)
        );
    }

    function testRevert_FeeOnTransferOutputCannotBypassMinimumDelivery() public {
        DeepstateFeeOnTransferToken feeToken = new DeepstateFeeOnTransferToken("Fee Token", "FEE");
        token0.mint(address(this), 100_000);
        feeToken.mint(address(deepstate), 100_000);
        token0.approve(address(facet), 100_000);
        deepstate.configure(address(token0), address(feeToken), 60_000, 50_000);

        vm.expectRevert(abi.encodeWithSelector(DeepstateFacet.NonStandardToken.selector, address(feeToken)));

        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            receiver,
            0,
            _swapData(address(token0), address(feeToken), 100_000)
        );
    }

    function testSwapsERC20ToNative() public {
        token0.mint(address(this), 100);
        token0.approve(address(facet), 100);
        vm.deal(address(deepstate), 50);
        deepstate.configure(address(token0), address(0), 60, 50);

        uint256 amountOut = facet.swapTokensViaDeepstate(
            bytes32(uint256(1)), "integrator", "referrer", receiver, 50, _swapData(address(token0), address(0), 100)
        );

        assertEq(amountOut, 50);
        assertEq(receiver.balance, 50);
        assertEq(token0.balanceOf(receiver), 40);
        assertEq(token0.allowance(address(facet), address(deepstate)), 0);
    }

    function testPreservesPreExistingDiamondBalances() public {
        token0.mint(address(facet), 17);
        token1.mint(address(facet), 19);
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);

        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            receiver,
            50,
            _swapData(address(token0), address(token1), 100)
        );

        assertEq(token0.balanceOf(address(facet)), 17);
        assertEq(token1.balanceOf(address(facet)), 19);
        assertEq(token0.balanceOf(receiver), 40);
        assertEq(token1.balanceOf(receiver), 50);
    }

    function testExactAllowancePreventsEngineOverpull() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 101, 50);

        vm.expectRevert();
        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)), "integrator", "referrer", receiver, 0, _swapData(address(token0), address(token1), 100)
        );

        assertEq(token0.balanceOf(address(this)), 100);
        assertEq(token0.balanceOf(address(deepstate)), 0);
        assertEq(token1.balanceOf(address(deepstate)), 50);
        assertEq(token0.allowance(address(facet), address(deepstate)), 0);
        assertEq(deepstate.callCount(), 0);
    }

    function testEngineRevertIsAtomic() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);
        deepstate.setShouldRevert(true);

        vm.expectRevert(MockDeepstateV1.FillFailed.selector);
        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)), "integrator", "referrer", receiver, 0, _swapData(address(token0), address(token1), 100)
        );

        assertEq(token0.balanceOf(address(this)), 100);
        assertEq(token1.balanceOf(address(deepstate)), 50);
        assertEq(token0.allowance(address(facet), address(deepstate)), 0);
    }

    function testNativeReceiverFailureIsAtomic() public {
        DeepstateRejectingReceiver rejectingReceiver = new DeepstateRejectingReceiver();
        token0.mint(address(this), 100);
        token0.approve(address(facet), 100);
        vm.deal(address(deepstate), 50);
        deepstate.configure(address(token0), address(0), 60, 50);

        vm.expectRevert();
        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            payable(address(rejectingReceiver)),
            0,
            _swapData(address(token0), address(0), 100)
        );

        assertEq(token0.balanceOf(address(this)), 100);
        assertEq(address(deepstate).balance, 50);
        assertEq(deepstate.callCount(), 0);
    }

    function testBlocksEngineReentrancy() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);

        DeepstateFacet.DeepstateSwapData memory nestedData = _swapData(address(token0), address(token1), 1);
        deepstate.setReentry(
            abi.encodeCall(
                facet.swapTokensViaDeepstate, (bytes32(uint256(2)), "nested", "nested", receiver, 0, nestedData)
            )
        );

        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            receiver,
            50,
            _swapData(address(token0), address(token1), 100)
        );

        assertTrue(deepstate.reentryAttempted());
        assertFalse(deepstate.reentrySucceeded());
        assertEq(deepstate.callCount(), 1);
    }

    function testRevertsBelowMinimumOutput() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);

        vm.expectRevert(abi.encodeWithSelector(CumulativeSlippageTooHigh.selector, 51, 50));
        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            receiver,
            51,
            _swapData(address(token0), address(token1), 100)
        );
    }

    function testRevertsForNonConfiguredDeepstateContract() public {
        MockDeepstateV1 nonConfigured = new MockDeepstateV1();
        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(token0), address(token1), 100);
        swapData.deepstate = nonConfigured;

        vm.expectRevert(ContractCallNotAllowed.selector);
        facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);
    }

    function testRejectsInvalidEnvelope() public {
        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(token0), address(token1), 100);
        delete swapData.fills;
        vm.expectRevert(NoSwapDataProvided.selector);
        facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);

        swapData = _swapData(address(token0), address(token0), 100);
        vm.expectRevert(InvalidSendingToken.selector);
        facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);

        swapData = _swapData(address(token0), address(token1), 100);
        vm.expectRevert(InvalidAmount.selector);
        facet.swapTokensViaDeepstate{value: 1}(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);

        swapData = _swapData(address(0), address(token1), 100);
        vm.expectRevert(InvalidAmount.selector);
        facet.swapTokensViaDeepstate{value: 99}(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);
    }

    function testRejectsFillForUndeclaredPair() public {
        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(token0), address(token1), 100);
        swapData.fills[0].token1 = address(0xCAFE);

        vm.expectRevert(InvalidCallData.selector);
        facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);
    }

    function testRejectsFillInOppositeDirection() public {
        DeepstateFacet.DeepstateSwapData memory swapData = _swapData(address(token0), address(token1), 100);
        swapData.fills[0].isBid = !swapData.fills[0].isBid;

        vm.expectRevert(InvalidCallData.selector);
        facet.swapTokensViaDeepstate(bytes32(uint256(1)), "integrator", "referrer", receiver, 0, swapData);
    }

    function testZeroReceiverRevertsAtomically() public {
        token0.mint(address(this), 100);
        token1.mint(address(deepstate), 50);
        token0.approve(address(facet), 100);
        deepstate.configure(address(token0), address(token1), 60, 50);

        vm.expectRevert(InvalidReceiver.selector);
        facet.swapTokensViaDeepstate(
            bytes32(uint256(1)),
            "integrator",
            "referrer",
            payable(address(0)),
            0,
            _swapData(address(token0), address(token1), 100)
        );

        assertEq(token0.balanceOf(address(this)), 100);
        assertEq(token1.balanceOf(address(deepstate)), 50);
        assertEq(deepstate.callCount(), 0);
    }

    function _swapData(address inputToken, address outputToken, uint256 amount)
        private
        view
        returns (DeepstateFacet.DeepstateSwapData memory swapData)
    {
        bool isBid = inputToken > outputToken;
        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](1);
        fills[0] = IDeepstateV1.FillParams({
            token0: isBid ? outputToken : inputToken,
            token1: isBid ? inputToken : outputToken,
            epoch: 0,
            order: bytes32(0),
            isBid: isBid,
            noRest: false,
            fillOrKill: false
        });

        swapData = DeepstateFacet.DeepstateSwapData({
            deepstate: deepstate,
            sendingAssetId: inputToken,
            receivingAssetId: outputToken,
            fromAmount: amount,
            fills: fills
        });
    }
}
