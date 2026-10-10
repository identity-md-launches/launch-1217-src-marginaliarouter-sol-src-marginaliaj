// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MarginaliaTreasury} from "src/MarginaliaTreasury.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract TreasuryBoundariesTest is Fixture {
    function setUp() public {
        _setup();
    }

    function test_EmptyAndDustDoNotConsumeDailyOpportunity() public {
        uint32 last = treasury.lastDripDay();
        vm.expectRevert(MarginaliaTreasury.NothingToDrip.selector);
        treasury.drip();
        imd.transfer(address(treasury), 49);
        vm.expectRevert(MarginaliaTreasury.NothingToDrip.selector);
        treasury.drip();
        assertEq(treasury.lastDripDay(), last);
        imd.transfer(address(treasury), 1);
        vm.prank(carol);
        treasury.drip();
        assertEq(imd.balanceOf(address(treasury)), 49);
        assertEq(_claims(address(hook), address(imd)), 1);
        assertEq(treasury.lastDripDay(), block.timestamp / 1 days);
    }

    function test_DripUsesUtcDayAndDoesNotCatchUpMissedDays() public {
        imd.transfer(address(treasury), 10_000 ether);
        uint256 boundary = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(boundary - 1);
        treasury.drip();
        assertEq(imd.balanceOf(address(treasury)), 9800 ether);
        vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
        treasury.drip();
        vm.warp(boundary);
        treasury.drip();
        assertEq(imd.balanceOf(address(treasury)), 9604 ether);
        vm.warp(boundary + 30 days);
        treasury.drip();
        assertEq(imd.balanceOf(address(treasury)), 941192 ether / 100);
        assertEq(imd.allowance(address(treasury), address(hook)), 0);
    }

    function test_SameDayDonationCannotResetTheDripLimit() public {
        imd.transfer(address(treasury), 100 ether);
        treasury.drip();
        imd.transfer(address(treasury), 1000 ether);
        uint256 claims = _claims(address(hook), address(imd));
        vm.prank(bob);
        vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
        treasury.drip();
        assertEq(imd.balanceOf(address(treasury)), 1098 ether);
        assertEq(_claims(address(hook), address(imd)), claims);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DripConservesValueAndRoundsLessThanOneWei(uint256 initial) public {
        initial = bound(initial, 50, imd.balanceOf(address(this)));
        imd.transfer(address(treasury), initial);
        uint256 callerBefore = imd.balanceOf(carol);
        vm.prank(carol);
        treasury.drip();
        uint256 held = imd.balanceOf(address(treasury));
        uint256 credited = _claims(address(hook), address(imd));
        assertEq(held + credited, initial, "treasury outflow must equal funded claims");
        assertLe(credited * 50, initial);
        assertLt(initial - credited * 50, 50, "rounding exceeds one drip wei");
        assertEq(
            hook.refundPool(hook.today()) + hook.leaderboardPool(hook.week()) + hook.thesisPool(hook.week()),
            credited
        );
        assertEq(imd.balanceOf(carol), callerBefore, "permissionless caller takes no fee");
        assertEq(imd.allowance(address(treasury), address(hook)), 0);
    }
}

/// @dev Pulling hook with a controllable failure and an attempted nested drip.
contract TreasuryCallbackHook {
    MockERC20 public immutable imd;
    MarginaliaTreasury public treasury;
    bool public shouldRevert;
    bool public nestedSucceeded;
    bytes public nestedError;
    uint256 public funded;

    constructor(MockERC20 token) {
        imd = token;
        treasury = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        treasury.init(address(this));
    }

    function setFailure(bool enabled) external {
        shouldRevert = enabled;
    }

    function fundPot(uint256 amount) external {
        require(msg.sender == address(treasury), "only treasury");
        imd.transferFrom(msg.sender, address(this), amount);
        (nestedSucceeded, nestedError) = address(treasury).call(abi.encodeCall(treasury.drip, ()));
        funded += amount;
        require(!shouldRevert, "hook failure after pull");
    }
}

contract TreasuryCallbackTest is Test {
    function test_ReentrantDripIsRefusedAndFailedFundingCanRetry() public {
        vm.warp(100 days);
        MockERC20 imd = new MockERC20("IMD", "IMD", 1000 ether);
        TreasuryCallbackHook hook = new TreasuryCallbackHook(imd);
        MarginaliaTreasury treasury = hook.treasury();
        imd.transfer(address(treasury), 1000 ether);
        hook.setFailure(true);
        vm.expectRevert("hook failure after pull");
        treasury.drip();
        assertEq(treasury.lastDripDay(), 0);
        assertEq(imd.balanceOf(address(treasury)), 1000 ether);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.allowance(address(treasury), address(hook)), 0);
        hook.setFailure(false);
        treasury.drip();
        assertFalse(hook.nestedSucceeded());
        assertEq(hook.nestedError(), abi.encodeWithSelector(MarginaliaTreasury.AlreadyDripped.selector));
        assertEq(hook.funded(), 20 ether);
        assertEq(imd.balanceOf(address(treasury)), 980 ether);
    }
}
