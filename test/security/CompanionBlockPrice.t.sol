// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../helpers/Fixture.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev The hook's revision prices every note at the block-open price (`blockPrice`), never at a price moved
/// inside the same block. These tests cover what the companions see of that: the router's noted-sell minimum
/// and deposit, a traded note whose X leg is the bound pool itself, and the judge's conversion floor.
contract CompanionBlockPriceTest is Fixture {
    function setUp() public {
        _setup();
        token.transfer(bob, 1_000_000 ether);
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
    }

    function _depositAt(uint256 price) internal view returns (uint256) {
        return FullMath.mulDiv(hook.DEPOSIT(), 1e18, price);
    }

    /// @dev The PoolManager wraps a hook revert; this is the exact error the router surfaces.
    function _hookRevert(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _assertRouterEmpty() internal view {
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_SameBlockPumpCannotLowerTheNotedSellMinimumOrDeposit() public {
        vm.roll(block.number + 1);
        uint256 open = hook.margPriceInImd();
        // Same block, before the noted sell: pump MARG by more than 10% through a plain router.
        _buy(bob, 600_000 ether);
        uint256 spot = hook.margPriceInImd();
        assertGt(spot * 100, open * 110);
        assertEq(hook.blockPrice(), open);
        uint256 atSpot = _depositAt(spot);
        uint256 atOpen = _depositAt(open);
        assertGt(atOpen, atSpot, "the lower price sizes the larger deposit");

        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "sell call after a pump");
        uint256 beforeMarg = token.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        bytes memory tooSmall = _hookRevert(IHooks.beforeSwap.selector, MarginaliaHook.NoteTooSmall.selector);
        // A sell sized for the pumped spot is below the minimum the block-open price sets.
        vm.prank(alice);
        vm.expectRevert(tooSmall);
        router.sellWithNote(p, atSpot * 2 + 1, 1, block.timestamp);
        // Exactly twice the open-price deposit is still too small; one wei more is enough.
        vm.prank(alice);
        vm.expectRevert(tooSmall);
        router.sellWithNote(p, atOpen * 2, 1, block.timestamp);
        assertEq(token.balanceOf(alice), beforeMarg);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(hook.noteCount(), 0);
        assertEq(_claims(address(hook), address(token)), 0);
        _assertRouterEmpty();

        vm.prank(alice);
        uint256 received = router.sellWithNote(p, atOpen * 2 + 1, 1, block.timestamp);
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(n.author, alice);
        assertEq(n.deposit, atOpen, "the deposit is sized at the block-open price the pump could not move");
        assertLe(n.postPrice, open);
        assertEq(beforeMarg - token.balanceOf(alice), atOpen * 2 + 1);
        assertEq(imd.balanceOf(alice) - beforeImd, received);
        assertGt(received, 0);
        assertEq(_claims(address(hook), address(token)), atOpen);
        _assertRouterEmpty();
    }

    function test_SameBlockDumpBeforeANotedSellCountsAgainstTheAuthor() public {
        vm.roll(block.number + 1);
        uint256 open = hook.margPriceInImd();
        _sell(bob, 600_000 ether);
        uint256 spot = hook.margPriceInImd();
        assertLt(spot * 100, open * 90);
        // The deposit follows the lower price (now the spot), so a dump never shrinks what is at stake.
        uint256 atSpot = _depositAt(spot);
        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "sell call after a dump");
        vm.prank(alice);
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, MarginaliaHook.NoteTooSmall.selector));
        router.sellWithNote(p, atSpot * 2, 1, block.timestamp);
        vm.prank(alice);
        router.sellWithNote(p, atSpot * 2 + 1, 1, block.timestamp);
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(n.deposit, atSpot);
        assertGt(n.deposit, _depositAt(open));
        // A sell posts at the lower of open and spot: the depressed spot, which the call then has to beat.
        assertLe(n.postPrice, spot);
        assertLt(n.postPrice, open);
    }

    function test_TradedNoteOnTheBoundPoolCountsTheAuthorsOwnImpact() public {
        vm.roll(block.number + 1);
        uint256 open = hook.margPriceInImd();
        MarginaliaRouter.XTrade memory x;
        x.kind = router.X_V4();
        x.key = key;
        x.zeroForOne = !margIs0; // IMD in, MARG out: a plain, untaxed buy on the bound pool
        x.amountIn = 100_000 ether;
        x.minOut = 1;
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "traded on the bound pool");
        uint256 beforeMarg = token.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 received = router.tradeAndNote(x, p, 10 ether, 1, block.timestamp);
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(n.author, alice);
        assertEq(n.x, address(token));
        assertEq(n.class, uint8(T.Class.Traded));
        uint256 spot = hook.margPriceInImd();
        assertGt(spot * 1000, open * 1010);
        assertEq(hook.blockPrice(), open);
        // A buy posts at the higher of open and spot: the author's own push is the price to beat.
        assertEq(n.postPrice, spot);
        assertEq(beforeImd - imd.balanceOf(alice), 100_010 ether);
        assertGt(token.balanceOf(alice) - beforeMarg, received, "X leg output arrives on top of the note's");
        assertEq(n.postBalance, token.balanceOf(alice));
        assertEq(_claims(address(hook), address(imd)), hook.STAMP());
        assertEq(_claims(address(hook), address(token)), n.deposit);
        _assertRouterEmpty();
    }

    function test_TradedSellSubjectMustBeTheTokenSoldEvenOnTheBoundPool() public {
        MarginaliaRouter.XTrade memory x;
        x.kind = router.X_V4();
        x.key = key;
        x.zeroForOne = !margIs0; // buys MARG
        x.amountIn = 1_000 ether;
        x.minOut = 1;
        // A SELL call about MARG with a buy leg: the token sold is IMD, not the note's subject.
        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "sell call with a buy leg");
        uint256 beforeImd = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.NoteTokenMismatch.selector);
        router.tradeAndNote(x, p, 10 ether, 1, block.timestamp);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(hook.noteCount(), 0);
        _assertRouterEmpty();
    }

    function test_ConversionDeliversAtLeastTheFloorOfTheSpotItReads() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "a"), 10 ether);
        vm.prank(alice);
        hook.retract(id, "out");
        uint256 pot = hook.potMarg();
        assertGt(pot, 0);
        vm.roll(block.number + 1);
        uint256 spot = hook.margPriceInImd();
        assertEq(hook.blockPrice(), spot);
        uint256 imdBefore = _claims(address(hook), address(imd));
        uint256 out = judge.convertForfeits();
        uint256 value = FullMath.mulDiv(pot, spot, 1e18);
        assertGe(out, value * judge.CONVERT_MIN_BPS() / 10_000, "below the judge's own floor");
        assertLt(out, value, "the LP fee and impact cost something");
        assertEq(hook.potMarg(), 0);
        assertEq(_claims(address(hook), address(imd)) - imdBefore, out);
        assertEq(_claims(address(hook), address(token)), 0);
    }
}
