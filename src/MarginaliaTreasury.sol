// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IHookPot {
    function imd() external view returns (address);
    function fundPot(uint256 amount) external;
}

/// @notice Holds what the project is given (prize money, the launch remainder, gifts) and drips 2% of its
/// IMD into the hook's pot once a day. No owner, no withdraw. ETH and other tokens wait for a sweep
/// (v1: anyone may hand IMD in; conversions of other assets are a documented follow-up).
contract MarginaliaTreasury {
    using SafeERC20 for IERC20;

    uint256 public constant DRIP_BPS = 200;
    IHookPot public hook;
    uint32 public lastDripDay;

    error AlreadyDripped();
    error NothingToDrip();
    error AlreadyInitialised();

    event Dripped(uint32 indexed day, uint256 amount);
    event Received(address indexed from, uint256 amount);

    /// @dev Called once by the hook on its clone, in the hook's constructor.
    function init(address hook_) external {
        if (address(hook) != address(0)) revert AlreadyInitialised();
        require(hook_ != address(0), "configuration required");
        hook = IHookPot(hook_);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Anyone, once per UTC day: 2% of the IMD balance into today's pot.
    function drip() external {
        uint32 day = uint32(block.timestamp / 1 days);
        if (day == lastDripDay) revert AlreadyDripped();
        IERC20 imd = IERC20(hook.imd());
        uint256 amount = imd.balanceOf(address(this)) * DRIP_BPS / 10_000;
        if (amount == 0) revert NothingToDrip();
        lastDripDay = day;
        imd.forceApprove(address(hook), amount);
        hook.fundPot(amount);
        emit Dripped(day, amount);
    }
}
