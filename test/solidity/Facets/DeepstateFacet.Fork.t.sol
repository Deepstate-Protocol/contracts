// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {ContractCallNotAllowed} from "lifi/Errors/GenericErrors.sol";
import {DeepstateFacet} from "lifi/Facets/DeepstateFacet.sol";
import {DiamondCutFacet} from "lifi/Facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "lifi/Facets/DiamondLoupeFacet.sol";
import {GenericSwapFacetV3} from "lifi/Facets/GenericSwapFacetV3.sol";
import {OwnershipFacet} from "lifi/Facets/OwnershipFacet.sol";
import {IDeepstateV1} from "lifi/Interfaces/IDeepstateV1.sol";
import {IWhitelistManagerFacet} from "lifi/Interfaces/IWhitelistManagerFacet.sol";
import {LibDiamond} from "lifi/Libraries/LibDiamond.sol";
import {LibSwap} from "lifi/Libraries/LibSwap.sol";
import {DeepstateTestToken} from "../utils/MockDeepstateV1.sol";

interface IDeepstateV1Fork is IDeepstateV1 {
    function fill(FillParams calldata params) external payable returns (bytes32 restingOrder);
    function feeConfig() external view returns (address recipient, uint16 bps);
    function bookId(address token0, address token1, uint256 epoch) external pure returns (bytes32);
    function roots(address token0, address token1, uint256 epoch)
        external
        view
        returns (bytes32 askRoot, bytes32 bidRoot);
}

contract DeepstateFacetRobinhoodForkTest is Test {
    uint256 private constant FORK_BLOCK = 45_093_213;
    uint160 private constant MAKER_QUANTITY = 100 ether;
    uint160 private constant TAKER_QUANTITY = 120 ether;
    address private constant LIFI_DIAMOND = 0xB477751B76CF82d00a686A1232f5fCD772414Af3;
    IDeepstateV1Fork private constant DEEPSTATE = IDeepstateV1Fork(0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96);

    DeepstateFacet private facet;
    DeepstateTestToken private token0;
    DeepstateTestToken private token1;
    address private maker = address(0xA11CE);
    address payable private receiver = payable(address(0xBEEF));
    uint16 private protocolFeeBps;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_NODE_URI_ROBINHOOD"), FORK_BLOCK);
        assertEq(block.chainid, 4663, "fork must be Robinhood Chain");
        assertGt(address(DEEPSTATE).code.length, 0, "live engine missing");
        assertGt(LIFI_DIAMOND.code.length, 0, "live diamond missing");

        DiamondLoupeFacet loupe = DiamondLoupeFacet(LIFI_DIAMOND);
        assertEq(
            loupe.facetAddress(DeepstateFacet.swapTokensViaDeepstate.selector),
            address(0),
            "Deepstate selector already installed"
        );
        assertTrue(
            loupe.facetAddress(GenericSwapFacetV3.swapTokensSingleV3ERC20ToERC20.selector) != address(0),
            "GenericSwapFacetV3 missing"
        );
        assertFalse(
            IWhitelistManagerFacet(LIFI_DIAMOND)
                .isContractSelectorWhitelisted(address(DEEPSTATE), IDeepstateV1.fillRoute.selector),
            "Deepstate must not use the shared allowlist"
        );
        assertEq(
            IWhitelistManagerFacet(LIFI_DIAMOND).getWhitelistedSelectorsForContract(address(DEEPSTATE)).length,
            0,
            "Deepstate engine must be completely absent from the shared allowlist"
        );

        DeepstateFacet implementation = new DeepstateFacet(DEEPSTATE);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DeepstateFacet.swapTokensViaDeepstate.selector;
        LibDiamond.FacetCut[] memory cut = new LibDiamond.FacetCut[](1);
        cut[0] = LibDiamond.FacetCut({
            facetAddress: address(implementation), action: LibDiamond.FacetCutAction.Add, functionSelectors: selectors
        });

        vm.prank(OwnershipFacet(LIFI_DIAMOND).owner());
        DiamondCutFacet(LIFI_DIAMOND).diamondCut(cut, address(0), bytes(""));
        facet = DeepstateFacet(payable(LIFI_DIAMOND));

        DeepstateTestToken first = new DeepstateTestToken("Deepstate Fork A", "DSA");
        DeepstateTestToken second = new DeepstateTestToken("Deepstate Fork B", "DSB");
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);

        (address feeRecipient, uint16 feeBps) = DEEPSTATE.feeConfig();
        assertTrue(feeRecipient != address(0), "protocol fee recipient missing");
        assertEq(feeBps, 10, "unexpected live protocol fee");
        protocolFeeBps = feeBps;

        token1.mint(maker, MAKER_QUANTITY);
        vm.startPrank(maker);
        token1.approve(address(DEEPSTATE), MAKER_QUANTITY);
        bytes32 restingOrder = DEEPSTATE.fill(_fill(MAKER_QUANTITY, true, false));
        vm.stopPrank();

        assertTrue(restingOrder != bytes32(0), "maker bid did not rest");
    }

    function test_RoutesThroughLiveDiamondAgainstLiveEngine() public {
        token0.mint(address(this), TAKER_QUANTITY);
        token0.approve(LIFI_DIAMOND, TAKER_QUANTITY);

        uint256 expectedOut = MAKER_QUANTITY - MAKER_QUANTITY * protocolFeeBps / 10_000;
        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](1);
        fills[0] = _fill(TAKER_QUANTITY, false, false);
        DeepstateFacet.DeepstateSwapData memory swapData = DeepstateFacet.DeepstateSwapData({
            deepstate: DEEPSTATE,
            sendingAssetId: address(token0),
            receivingAssetId: address(token1),
            fromAmount: TAKER_QUANTITY,
            fills: fills
        });

        uint256 amountOut = facet.swapTokensViaDeepstate(
            bytes32(uint256(1)), "integrator", "referrer", receiver, expectedOut, swapData
        );

        assertEq(amountOut, expectedOut, "live output");
        assertEq(token0.balanceOf(receiver), TAKER_QUANTITY - MAKER_QUANTITY, "unmatched input refund");
        assertEq(token1.balanceOf(receiver), expectedOut, "receiver output");
        assertEq(token0.balanceOf(address(DEEPSTATE)), MAKER_QUANTITY, "engine input settlement");
        assertEq(token0.balanceOf(LIFI_DIAMOND), 0, "diamond input residue");
        assertEq(token1.balanceOf(LIFI_DIAMOND), 0, "diamond output residue");
        assertEq(token0.allowance(LIFI_DIAMOND, address(DEEPSTATE)), 0, "temporary allowance");

        (bytes32 askRoot, bytes32 bidRoot) = DEEPSTATE.roots(address(token0), address(token1), 0);
        assertEq(askRoot, bytes32(0), "unmatched ask rested");
        assertEq(bidRoot, bytes32(0), "maker bid not consumed");
    }

    function test_GenericSwapFacetCannotInvokeDeepstateFillRoute() public {
        uint256 userDeposit = 1 ether;
        uint256 diamondBalance = 10 ether;
        uint160 encodedQuantity = uint160(userDeposit + diamondBalance);

        token0.mint(address(this), userDeposit);
        token0.mint(LIFI_DIAMOND, diamondBalance);
        token0.approve(LIFI_DIAMOND, userDeposit);

        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](1);
        fills[0] = _fill(encodedQuantity, false, true);
        LibSwap.SwapData memory swapData = LibSwap.SwapData({
            callTo: address(DEEPSTATE),
            approveTo: address(DEEPSTATE),
            sendingAssetId: address(token0),
            receivingAssetId: address(token1),
            fromAmount: userDeposit,
            callData: abi.encodeCall(IDeepstateV1.fillRoute, (fills)),
            requiresDeposit: true
        });

        vm.expectRevert(ContractCallNotAllowed.selector);
        GenericSwapFacetV3(LIFI_DIAMOND)
            .swapTokensSingleV3ERC20ToERC20(bytes32(uint256(2)), "integrator", "referrer", receiver, 1, swapData);

        assertEq(token0.balanceOf(address(this)), userDeposit, "caller deposit changed");
        assertEq(token0.balanceOf(LIFI_DIAMOND), diamondBalance, "diamond balance changed");
        assertEq(token1.balanceOf(receiver), 0, "route unexpectedly executed");
        assertEq(token0.allowance(LIFI_DIAMOND, address(DEEPSTATE)), 0, "engine approval unexpectedly set");
    }

    function _fill(uint160 quantity, bool isBid, bool noRest)
        private
        view
        returns (IDeepstateV1.FillParams memory params)
    {
        params = IDeepstateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: 0,
            order: bytes32(uint256(quantity) << 64),
            isBid: isBid,
            noRest: noRest,
            fillOrKill: false
        });
    }
}
