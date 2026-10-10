// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../helpers/Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Factory, MockV3Pool, MockV2Factory} from "../Companions.t.sol";
import {CheckedV2Pair} from "../mocks/CheckedV2Pair.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract RouterAdversarialTest is Fixture {
    using PoolIdLibrary for PoolKey;
    MockERC20 x;
    MockV3Factory v3Factory;
    MockV2Factory v2Factory;
    MockV3Pool v3;
    CheckedV2Pair v2;
    PoolKey xKey;

    function setUp() public {
        _setup();
        x = new MockERC20("X", "X", 1_000_000 ether);
        vm.etch(router.V3_FACTORY(), address(new MockV3Factory()).code);
        vm.etch(router.V2_FACTORY(), address(new MockV2Factory()).code);
        v3Factory = MockV3Factory(router.V3_FACTORY());
        v2Factory = MockV2Factory(router.V2_FACTORY());
        v3 = new MockV3Pool(address(imd), address(x), 3000, 8000);
        v2 = new CheckedV2Pair(address(imd), address(x));
        v3Factory.register(v3.token0(), v3.token1(), 3000, address(v3));
        v2Factory.register(address(imd), address(x), address(v2));
        imd.transfer(address(v3), 10_000 ether);
        x.transfer(address(v3), 10_000 ether);
        imd.transfer(address(v2), 10_000 ether);
        x.transfer(address(v2), 10_000 ether);
        v2.sync();
        x.transfer(alice, 10_000 ether);
        vm.startPrank(alice);
        x.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        (address c0, address c1) =
            address(imd) < address(x) ? (address(imd), address(x)) : (address(x), address(imd));
        xKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(xKey, uint160(1 << 96));
        x.transfer(address(liquidity), 50_000 ether);
        liquidity.add(xKey, -600, 600, 100_000 ether);
    }

    function _thesis(T.Side side) internal view returns (T.NoteParams memory p) {
        p.x = address(x);
        p.side = side;
        p.class = uint8(T.Class.Declared);
        p.text = "X thesis with evidence";
    }

    function _trade(uint8 kind, bool buyX, uint256 amount)
        internal
        view
        returns (MarginaliaRouter.XTrade memory t)
    {
        t.kind = kind;
        t.key = xKey;
        t.tokenIn = buyX ? address(imd) : address(x);
        t.zeroForOne = t.tokenIn == Currency.unwrap(xKey.currency0);
        t.pool = kind == 2 ? address(v3) : address(v2);
        t.amountIn = amount;
        t.minOut = 1;
    }

    function _assertEmpty() internal view {
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(x.balanceOf(address(router)), 0);
    }

    function test_RejectsExpiredZeroAndOversizedNoteAmountsBeforePullingFunds() public {
        T.NoteParams memory p = _thesis(T.Side.Buy);
        uint256 balance = imd.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.Expired.selector);
        router.note(p, 10 ether, 1, block.timestamp - 1);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.note(p, 0, 0, block.timestamp);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.note(p, uint256(uint128(type(int128).max)) + 1, 0, block.timestamp);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.sellWithNote(p, type(uint256).max, 0, block.timestamp);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), balance);
        assertEq(hook.noteCount(), 0);
        _assertEmpty();
    }

    function test_ExactDeadlineWorksAndSlippageRollsBackTheNoteAndClaims() public {
        T.NoteParams memory p = _thesis(T.Side.Buy);
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.Slippage.selector);
        router.note(p, 10 ether, type(uint256).max, block.timestamp);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(token.balanceOf(alice), beforeMarg);
        assertEq(hook.noteCount(), 0);
        assertEq(_claims(address(hook), address(imd)), 0);
        assertEq(_claims(address(hook), address(token)), 0);
        vm.prank(alice);
        uint256 received = router.note(p, 10 ether, 1, block.timestamp);
        assertEq(token.balanceOf(alice) - beforeMarg, received);
        assertEq(beforeImd - imd.balanceOf(alice), 10 ether);
        assertEq(hook.noteOf(bytes32(uint256(1))).author, alice);
        _assertEmpty();
    }

    function test_SellSlippageRestoresDepositFeeAndPayerBalance() public {
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.Slippage.selector);
        router.sellWithNote(_thesis(T.Side.Sell), 100 ether, type(uint256).max, block.timestamp);
        assertEq(token.balanceOf(alice), beforeMarg);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(hook.noteCount(), 0);
        assertEq(_claims(address(hook), address(imd)), 0);
        vm.prank(alice);
        uint256 received = router.sellWithNote(_thesis(T.Side.Sell), 100 ether, 1, block.timestamp);
        assertEq(imd.balanceOf(alice) - beforeImd, received);
        assertEq(beforeMarg - token.balanceOf(alice), 100 ether);
        _assertEmpty();
    }

    function test_ZeroXLegAndNativeInputAreRefusedAtomically() public {
        MarginaliaRouter.XTrade memory t = _trade(0, true, 1 ether);
        T.NoteParams memory p = _thesis(T.Side.Buy);
        uint256 balance = imd.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        t = _trade(1, true, 0);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        t.amountIn = 1 ether;
        t.key.currency0 = Currency.wrap(address(0));
        t.zeroForOne = true;
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), balance);
        _assertEmpty();
    }

    function test_IdleCallbacksCannotSpendPreexistingFundsEvenFromTheManagerOrPool() public {
        imd.transfer(address(router), 5 ether);
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.unlockCallback(hex"1234");
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.unlockCallback(hex"1234");
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1 ether, 0, "");
        vm.prank(address(v3));
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1 ether, 0, "");
        assertEq(imd.balanceOf(address(router)), 5 ether);
    }

    function test_AllVenuesRejectWrongBuyAndSellSubjectsAndRollBackBothLegs() public {
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeX = x.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        for (uint8 kind = 1; kind <= 3; ++kind) {
            for (uint256 side; side < 2; ++side) {
                T.NoteParams memory p = _thesis(T.Side(side));
                p.x = address(token);
                MarginaliaRouter.XTrade memory t = _trade(kind, side == 0, 5 ether);
                vm.prank(alice);
                vm.expectRevert(MarginaliaRouter.NoteTokenMismatch.selector);
                router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
                assertEq(imd.balanceOf(alice), beforeImd);
                assertEq(x.balanceOf(alice), beforeX);
                assertEq(token.balanceOf(alice), beforeMarg);
                assertEq(hook.noteCount(), 0);
                _assertEmpty();
            }
        }
    }

    function test_AllVenuesEnforceBothSlippageLimitsAndRollbackVenueTransfers() public {
        for (uint8 kind = 1; kind <= 3; ++kind) {
            uint256 imdBefore = imd.balanceOf(alice);
            uint256 xBefore = x.balanceOf(alice);
            MarginaliaRouter.XTrade memory t = _trade(kind, true, 5 ether);
            uint256 venueImd = imd.balanceOf(kind == 1 ? address(manager) : t.pool);
            uint256 venueX = x.balanceOf(kind == 1 ? address(manager) : t.pool);
            t.minOut = type(uint256).max;
            vm.prank(alice);
            vm.expectRevert(MarginaliaRouter.Slippage.selector);
            router.tradeAndNote(t, _thesis(T.Side.Buy), 10 ether, 1, block.timestamp);
            t.minOut = 1;
            vm.prank(alice);
            vm.expectRevert(MarginaliaRouter.Slippage.selector);
            router.tradeAndNote(t, _thesis(T.Side.Buy), 10 ether, type(uint256).max, block.timestamp);
            assertEq(imd.balanceOf(alice), imdBefore);
            assertEq(x.balanceOf(alice), xBefore);
            assertEq(imd.balanceOf(kind == 1 ? address(manager) : t.pool), venueImd);
            assertEq(x.balanceOf(kind == 1 ? address(manager) : t.pool), venueX);
            assertEq(hook.noteCount(), 0);
            _assertEmpty();
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TradeAndNoteBothDirections(uint8 venue, bool buyX, uint96 amountSeed) public {
        uint8 kind = uint8(bound(venue, 1, 3));
        uint256 amount = bound(amountSeed, 1e6, 100 ether);
        MarginaliaRouter.XTrade memory t = _trade(kind, buyX, amount);
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 xBefore = x.balanceOf(alice);
        uint256 margBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 received =
            router.tradeAndNote(t, _thesis(buyX ? T.Side.Buy : T.Side.Sell), 10 ether, 1, block.timestamp);
        assertEq(token.balanceOf(alice) - margBefore, received);
        if (buyX) {
            assertGt(x.balanceOf(alice), xBefore);
            assertLe(imdBefore - imd.balanceOf(alice), amount + 10 ether);
            assertGt(imdBefore - imd.balanceOf(alice), 10 ether);
        } else {
            assertLt(x.balanceOf(alice), xBefore);
            assertLe(xBefore - x.balanceOf(alice), amount);
            assertGt(imd.balanceOf(alice) + 10 ether, imdBefore);
        }
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(n.author, alice);
        assertEq(n.x, address(x));
        assertEq(n.class, uint8(T.Class.Traded));
        // Only the fixed stamp accrues on a noted buy: no additional 0.25% action fee.
        assertEq(_claims(address(hook), address(imd)), hook.STAMP());
        _assertEmpty();
    }

    function test_V4PartialFillRefundsOnlyTheXBudgetWhenBothInputsAreImd() public {
        MarginaliaRouter.XTrade memory t = _trade(1, true, 100_000 ether);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        router.tradeAndNote(t, _thesis(T.Side.Buy), 10 ether, 1, block.timestamp);
        uint256 spent = imdBefore - imd.balanceOf(alice);
        assertGt(spent, 10 ether);
        assertLt(spent, 100_010 ether, "X pool should exhaust its narrow range");
        assertEq(hook.noteCount(), 1);
        _assertEmpty();
    }

    function test_V3PartialFillCannotRefundUnrelatedDonations() public {
        imd.transfer(address(router), 13 ether);
        x.transfer(address(router), 7 ether);
        uint256 beforeImd = imd.balanceOf(alice);
        vm.prank(alice);
        router.tradeAndNote(_trade(2, true, 5 ether), _thesis(T.Side.Buy), 10 ether, 1, block.timestamp);
        assertEq(beforeImd - imd.balanceOf(alice), 14 ether);
        assertEq(imd.balanceOf(address(router)), 13 ether);
        assertEq(x.balanceOf(address(router)), 7 ether);
        // The pool's authorization is cleared when the leg returns.
        vm.prank(address(v3));
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1 ether, 0, "");
    }

    function test_CanonicalV2AndV3StillRejectAnInputTokenOutsideThePool() public {
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        for (uint8 kind = 2; kind <= 3; ++kind) {
            MarginaliaRouter.XTrade memory t = _trade(kind, true, 5 ether);
            t.tokenIn = address(token);
            vm.prank(alice);
            vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
            router.tradeAndNote(t, _thesis(T.Side.Buy), 10 ether, 1, block.timestamp);
            assertEq(imd.balanceOf(alice), beforeImd);
            assertEq(token.balanceOf(alice), beforeMarg);
            assertEq(hook.noteCount(), 0);
            _assertEmpty();
        }
    }
}
