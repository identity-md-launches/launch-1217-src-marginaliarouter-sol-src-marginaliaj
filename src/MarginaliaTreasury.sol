// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IHookPot {
    function imd() external view returns (address);
    function fundPot(uint256 amount) external;
}

/// @notice Holds what the project is given (prize money, the launch remainder, gifts) and drips 2% of its
/// IMD into the hook's pot once a day. No owner, no withdraw. Only IMD is useful here: the contract has no
/// receive function, so ETH sent to it reverts, and any other ERC-20 handed in cannot be moved (v1 has no
/// conversion; hand IMD in).
contract MarginaliaTreasury {
    using SafeERC20 for IERC20;

    uint256 public constant DRIP_BPS = 200;
    IHookPot public hook;
    uint32 public lastDripDay;

    error AlreadyDripped();
    error NothingToDrip();
    error AlreadyInitialised();

    event Dripped(uint32 indexed day, uint256 amount);

    /// @dev The implementation is an EIP-1167 target and is never a treasury itself: its constructor fills
    /// the init guard with its own address, so nobody can initialise the published implementation and point
    /// it at a hook of their choosing. A clone starts with empty storage, so its `init` still runs once.
    constructor() {
        hook = IHookPot(address(this));
    }

    /// @dev Called once by the hook on its clone, in the hook's constructor.
    function init(address hook_) external {
        if (address(hook) != address(0)) revert AlreadyInitialised();
        require(hook_ != address(0), "configuration required");
        hook = IHookPot(hook_);
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
