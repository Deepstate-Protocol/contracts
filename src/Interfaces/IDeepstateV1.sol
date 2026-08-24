// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title IDeepstateV1
/// @notice Minimal interface for executing atomic onchain routes through Deepstate V1.
/// @author LI.FI (https://li.fi)
/// @dev Mirrors the verified Robinhood Chain deployment at
///      0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96.
/// @custom:version 1.0.0
interface IDeepstateV1 {
    /// @notice One onchain order-book fill instruction.
    struct FillParams {
        address token0; // Lower token address in the sorted pair
        address token1; // Higher token address in the sorted pair
        uint256 epoch; // Book epoch to match against
        bytes32 order; // Packed incoming price, quantity, and zero nonce
        bool isBid; // True to buy token0 with token1
        bool noRest; // True to discard unmatched quantity
        bool fillOrKill; // True to require the complete quantity to match
    }

    /// @notice Executes every fill leg atomically and settles net token deltas once.
    /// @param _fills Sequential onchain fill instructions.
    function fillRoute(FillParams[] calldata _fills) external payable;
}
