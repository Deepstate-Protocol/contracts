// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDeepstateV1} from "lifi/Interfaces/IDeepstateV1.sol";

contract DeepstateTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeepstateFeeOnTransferToken is DeepstateTestToken {
    uint256 private constant FEE_BPS = 100;

    constructor(string memory name_, string memory symbol_) DeepstateTestToken(name_, symbol_) {}

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount * FEE_BPS / 10_000;
        _burn(from, fee);
        super._transfer(from, to, amount - fee);
    }
}

/// @dev Adversarial unit-test double for states that cannot be configured on the live engine:
/// forced reverts, attempted reentrancy, over-pulls, and deliberately non-standard token transfers.
/// Real packed-order matching, epochs, fees, and settlement are covered by the Robinhood fork test.
contract MockDeepstateV1 is IDeepstateV1 {
    error FillFailed();

    address public inputToken;
    address public outputToken;
    uint256 public inputAmount;
    uint256 public outputAmount;
    bool public allNoRest;
    bool public shouldRevert;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    uint256 public callCount;
    bytes private reentryData;

    function configure(address inputToken_, address outputToken_, uint256 inputAmount_, uint256 outputAmount_)
        external
    {
        inputToken = inputToken_;
        outputToken = outputToken_;
        inputAmount = inputAmount_;
        outputAmount = outputAmount_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setReentry(bytes calldata data) external {
        reentryData = data;
    }

    function fillRoute(FillParams[] calldata fills) external payable {
        if (shouldRevert) revert FillFailed();
        ++callCount;

        if (reentryData.length != 0) {
            reentryAttempted = true;
            (reentrySucceeded,) = msg.sender.call(reentryData);
        }

        allNoRest = true;
        for (uint256 i; i < fills.length;) {
            allNoRest = allNoRest && fills[i].noRest;
            unchecked {
                ++i;
            }
        }

        if (inputToken == address(0)) {
            payable(msg.sender).transfer(msg.value - inputAmount);
        } else {
            IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        }

        if (outputToken == address(0)) {
            (bool success,) = payable(msg.sender).call{value: outputAmount}("");
            require(success);
        } else {
            IERC20(outputToken).transfer(msg.sender, outputAmount);
        }
    }

    receive() external payable {}
}
