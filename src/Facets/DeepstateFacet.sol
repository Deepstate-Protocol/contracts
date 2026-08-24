// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {
    ContractCallNotAllowed,
    CumulativeSlippageTooHigh,
    InvalidAmount,
    InvalidCallData,
    InvalidReceiver,
    InvalidSendingToken,
    NoSwapDataProvided
} from "../Errors/GenericErrors.sol";
import {IDeepstateV1} from "../Interfaces/IDeepstateV1.sol";
import {ILiFi} from "../Interfaces/ILiFi.sol";
import {ReentrancyGuard} from "../Helpers/ReentrancyGuard.sol";
import {LibAsset} from "../Libraries/LibAsset.sol";
import {LibSwap} from "../Libraries/LibSwap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title DeepstateFacet
/// @author LI.FI (https://li.fi)
/// @notice Executes a Deepstate route without allowing unmatched quantity to rest in the LI.FI diamond.
/// @dev Deepstate matches a fully specified route atomically onchain. This facet only accepts direct
///      routes between the declared input and output assets. It is not intended to custody user funds;
///      balances should exist only transiently during execution and are forwarded or refunded afterward.
/// @custom:version 1.2.0
contract DeepstateFacet is ILiFi, ReentrancyGuard {
    using SafeTransferLib for address;

    IDeepstateV1 private immutable DEEPSTATE;

    /// @notice Deepstate supports only assets whose ERC20 transfers move the exact requested amount.
    /// @param token Token that exhibited non-standard balance movement.
    error NonStandardToken(address token);

    /// @notice Parameters for a self-funded Deepstate route.
    /// @param deepstate The matching engine, which must equal this facet's immutable engine.
    /// @param sendingAssetId The asset pulled from the caller. Address zero denotes native currency.
    /// @param receivingAssetId The asset delivered to `receiver`. Address zero denotes native currency.
    /// @param fromAmount The maximum input made available to the engine.
    /// @param fills Sequential matching legs. The facet forces every leg to `noRest`.
    struct DeepstateSwapData {
        IDeepstateV1 deepstate;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        IDeepstateV1.FillParams[] fills;
    }

    /// @notice Binds this facet deployment to one Deepstate engine.
    /// @param _deepstate The sole Deepstate engine this facet may call.
    constructor(IDeepstateV1 _deepstate) {
        if (!LibAsset.isContract(address(_deepstate))) revert ContractCallNotAllowed();
        DEEPSTATE = _deepstate;
    }

    /// @notice Executes a bounded Deepstate route and returns all resulting assets to `receiver`.
    /// @dev The engine is approved for at most `fromAmount` during this call. Any unused input is
    ///      refunded, and pre-existing diamond balances are excluded from both output and refunds.
    /// @param _transactionId The transaction identifier used for LI.FI analytics.
    /// @param _integrator The integrator identifier used for LI.FI analytics.
    /// @param _referrer The referrer identifier used for LI.FI analytics.
    /// @param _receiver The address receiving output and any unspent input.
    /// @param _minAmountOut The minimum acceptable output amount.
    /// @param _deepstateData The Deepstate engine, assets, amount, and onchain fill instructions.
    /// @return amountOut The amount of the receiving asset delivered to `_receiver`.
    function swapTokensViaDeepstate(
        bytes32 _transactionId,
        string calldata _integrator,
        string calldata _referrer,
        address payable _receiver,
        uint256 _minAmountOut,
        DeepstateSwapData calldata _deepstateData
    ) external payable nonReentrant returns (uint256 amountOut) {
        uint256 amountIn;

        if (_receiver == address(0)) revert InvalidReceiver();
        if (_deepstateData.fills.length == 0) revert NoSwapDataProvided();
        if (_deepstateData.sendingAssetId == _deepstateData.receivingAssetId) revert InvalidSendingToken();
        if (address(_deepstateData.deepstate) != address(DEEPSTATE)) {
            revert ContractCallNotAllowed();
        }

        _validateFills(_deepstateData.fills, _deepstateData.sendingAssetId, _deepstateData.receivingAssetId);

        {
            bool nativeInput = LibAsset.isNativeAsset(_deepstateData.sendingAssetId);
            if (nativeInput) {
                // Exact value keeps consumed-input accounting independent of caller overpayment.
                if (msg.value != _deepstateData.fromAmount) revert InvalidAmount();
            } else if (msg.value != 0) {
                revert InvalidAmount();
            }

            uint256 sendingBalance = LibAsset.getOwnBalance(_deepstateData.sendingAssetId);
            uint256 receivingBalance = LibAsset.getOwnBalance(_deepstateData.receivingAssetId);
            uint256 engineInputBalance;
            if (nativeInput) sendingBalance -= msg.value;
            else engineInputBalance = _deepstateData.sendingAssetId.balanceOf(address(DEEPSTATE));

            LibAsset.depositAsset(_deepstateData.sendingAssetId, _deepstateData.fromAmount);
            if (!nativeInput) {
                uint256 deposited = LibAsset.getOwnBalance(_deepstateData.sendingAssetId) - sendingBalance;
                if (deposited != _deepstateData.fromAmount) {
                    revert NonStandardToken(_deepstateData.sendingAssetId);
                }

                // Exact, temporary authority prevents route calldata from spending unrelated diamond balances.
                _deepstateData.sendingAssetId.safeApproveWithRetry(address(DEEPSTATE), _deepstateData.fromAmount);
            }

            IDeepstateV1.FillParams[] memory fills = _deepstateData.fills;
            for (uint256 i; i < fills.length;) {
                fills[i].noRest = true;
                unchecked {
                    ++i;
                }
            }

            DEEPSTATE.fillRoute{value: nativeInput ? _deepstateData.fromAmount : 0}(fills);

            if (!nativeInput) {
                _deepstateData.sendingAssetId.safeApprove(address(DEEPSTATE), 0);
            }

            amountOut = LibAsset.getOwnBalance(_deepstateData.receivingAssetId) - receivingBalance;
            if (amountOut < _minAmountOut) revert CumulativeSlippageTooHigh(_minAmountOut, amountOut);

            _transferAssetExact(_deepstateData.receivingAssetId, _receiver, amountOut);

            uint256 leftover = LibAsset.getOwnBalance(_deepstateData.sendingAssetId) - sendingBalance;
            amountIn = _deepstateData.fromAmount - leftover;
            if (!nativeInput) {
                uint256 engineInputBalanceAfter = _deepstateData.sendingAssetId.balanceOf(address(DEEPSTATE));
                if (
                    engineInputBalanceAfter < engineInputBalance
                        || engineInputBalanceAfter - engineInputBalance != amountIn
                ) {
                    revert NonStandardToken(_deepstateData.sendingAssetId);
                }
            }
            if (leftover != 0) {
                _transferAssetExact(_deepstateData.sendingAssetId, _receiver, leftover);
            }
        }

        emit LibSwap.AssetSwapped(
            _transactionId,
            address(DEEPSTATE),
            _deepstateData.sendingAssetId,
            _deepstateData.receivingAssetId,
            amountIn,
            amountOut,
            block.timestamp
        );
        emit LiFiGenericSwapCompleted(
            _transactionId,
            _integrator,
            _referrer,
            _receiver,
            _deepstateData.sendingAssetId,
            _deepstateData.receivingAssetId,
            amountIn,
            amountOut
        );
    }

    /// @dev Restricts a call to one direct market and direction. Multiple legs may consume
    ///      different book epochs, but cannot introduce an undeclared debit or output asset.
    function _validateFills(
        IDeepstateV1.FillParams[] calldata _fills,
        address _sendingAssetId,
        address _receivingAssetId
    ) private pure {
        for (uint256 i; i < _fills.length;) {
            IDeepstateV1.FillParams calldata fill = _fills[i];
            address inputAsset = fill.isBid ? fill.token1 : fill.token0;
            address outputAsset = fill.isBid ? fill.token0 : fill.token1;

            if (fill.token0 >= fill.token1 || inputAsset != _sendingAssetId || outputAsset != _receivingAssetId) {
                revert InvalidCallData();
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Native transfers are exact by construction. ERC20 delivery is checked by receiver
    ///      balance delta so fee-on-transfer, mint-on-transfer, and transfer-time rebasing assets
    ///      fail atomically instead of bypassing `_minAmountOut` on the final hop.
    function _transferAssetExact(address _assetId, address payable _receiver, uint256 _amount) private {
        if (LibAsset.isNativeAsset(_assetId) || _receiver == address(this)) {
            LibAsset.transferAsset(_assetId, _receiver, _amount);
            return;
        }

        uint256 balanceBefore = _assetId.balanceOf(_receiver);
        LibAsset.transferAsset(_assetId, _receiver, _amount);
        uint256 balanceAfter = _assetId.balanceOf(_receiver);
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != _amount) {
            revert NonStandardToken(_assetId);
        }
    }
}
