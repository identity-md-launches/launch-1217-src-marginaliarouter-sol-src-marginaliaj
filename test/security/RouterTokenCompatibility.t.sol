// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../helpers/Fixture.sol";
import {CheckedV2Pair} from "../mocks/CheckedV2Pair.sol";
import {MockV2Factory} from "../Companions.t.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RouterBehaviorToken is ERC20 {
    enum Mode {
        Normal,
        NoReturn,
        FalseReturn,
        Blocked,
        Reenter,
        Tax,
        FullTax
    }
    Mode public mode;
    uint8 private immutable units;
    MarginaliaRouter public router;
    bool public nestedSuccess;
    bytes public nestedError;

    constructor(uint8 decimals_, MarginaliaRouter r) ERC20("Behavior token", "BHV") {
        units = decimals_;
        router = r;
        _mint(msg.sender, 1_000_000 * 10 ** decimals_);
    }

    function decimals() public view override returns (uint8) {
        return units;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == Mode.FalseReturn) return false;
        require(mode != Mode.Blocked, "token transfers blocked");
        super.transfer(to, value);
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == Mode.FalseReturn) return false;
        require(mode != Mode.Blocked, "token transfers blocked");
        super.transferFrom(from, to, value);
        if (mode == Mode.Reenter) {
            T.NoteParams memory p;
            p.x = address(this);
            p.text = "nested note";
            (nestedSuccess, nestedError) =
                address(router).call(abi.encodeCall(router.note, (p, 1 ether, 0, block.timestamp)));
        }
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if ((mode == Mode.Tax || mode == Mode.FullTax) && from != address(0) && to != address(0)) {
            uint256 fee = mode == Mode.FullTax ? amount : amount / 10;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract RouterTokenCompatibilityTest is Fixture {
    RouterBehaviorToken x;
    CheckedV2Pair pair;

    function setUp() public {
        _setup();
        x = new RouterBehaviorToken(6, router);
        pair = new CheckedV2Pair(address(imd), address(x));
        imd.transfer(address(pair), 10_000 ether);
        x.transfer(address(pair), 10_000e6);
        pair.sync();
        x.transfer(alice, 1000e6);
        vm.prank(alice);
        x.approve(address(router), type(uint256).max);
        vm.etch(router.V2_FACTORY(), address(new MockV2Factory()).code);
        MockV2Factory(router.V2_FACTORY()).register(address(imd), address(x), address(pair));
    }

    function _args(bool buy, uint256 amount)
        internal
        view
        returns (MarginaliaRouter.XTrade memory t, T.NoteParams memory p)
    {
        t.kind = 3;
        t.pool = address(pair);
        t.tokenIn = buy ? address(imd) : address(x);
        t.amountIn = amount;
        t.minOut = 1;
        p.x = address(x);
        p.side = buy ? T.Side.Buy : T.Side.Sell;
        p.text = "Thesis on a six-decimal token";
    }

    function test_NoReturnTokenWorksInBothDirections() public {
        x.setMode(RouterBehaviorToken.Mode.NoReturn);
        uint256 beforeX = x.balanceOf(alice);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, 100e6);
        vm.prank(alice);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(x.balanceOf(alice), beforeX - 100e6);
        (t, p) = _args(true, 1 ether);
        vm.prank(alice);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertGt(x.balanceOf(alice), beforeX - 100e6);
        assertEq(x.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(hook.noteCount(), 2);
    }

    function test_FalseReturnAndBlockedTransfersRollbackTheImdAlreadyPulled() public {
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, 100e6);
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeX = x.balanceOf(alice);
        x.setMode(RouterBehaviorToken.Mode.FalseReturn);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(x)));
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        x.setMode(RouterBehaviorToken.Mode.Blocked);
        vm.prank(alice);
        vm.expectRevert("token transfers blocked");
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(x.balanceOf(alice), beforeX);
        assertEq(hook.noteCount(), 0);
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function test_TransferFromCannotReenterNotePosting() public {
        x.setMode(RouterBehaviorToken.Mode.Reenter);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, 100e6);
        vm.prank(alice);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertFalse(x.nestedSuccess());
        assertEq(
            x.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(hook.noteCount(), 1);
        assertEq(hook.noteOf(bytes32(uint256(1))).author, alice);
        assertEq(x.balanceOf(address(router)), 0);
    }

    function test_TaxedOutputUsesTheRecipientsNetBalanceForSlippage() public {
        x.setMode(RouterBehaviorToken.Mode.Tax);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(true, 1 ether);
        uint256 grossQuote = (uint256(1 ether) * 997 * 10_000e6) / (10_000 ether * 1000 + 1 ether * 997);
        t.minOut = grossQuote;
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeX = x.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.Slippage.selector);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(x.balanceOf(alice), beforeX);
        t.minOut = grossQuote - grossQuote / 10;
        vm.prank(alice);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(x.balanceOf(alice) - beforeX, t.minOut);
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function test_TaxedInputMeasuresBothTransfersWithoutUsingDonations() public {
        _taxedInput(100e6, 0);
        _taxedInput(100e6, 37e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TaxedInputPreservesDonationsAndAccountsForBothBurns(uint256 amount, uint256 donation)
        public
    {
        _taxedInput(bound(amount, 1, 1000e6), bound(donation, 0, 1000e6));
    }

    function _taxedInput(uint256 amount, uint256 donation) internal {
        x.setMode(RouterBehaviorToken.Mode.Normal);
        x.transfer(address(router), donation);
        imd.transfer(address(router), 13 ether);
        uint256 routerX = x.balanceOf(address(router));
        uint256 routerImd = imd.balanceOf(address(router));
        x.setMode(RouterBehaviorToken.Mode.Tax);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, amount);
        uint256 beforeX = x.balanceOf(alice);
        uint256 pairX = x.balanceOf(address(pair));
        uint256 pairImd = imd.balanceOf(address(pair));
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        uint256 supply = x.totalSupply();
        uint256 noteCount = hook.noteCount();
        vm.startPrank(alice);
        x.approve(address(router), amount);
        uint256 margOut = router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        vm.stopPrank();
        uint256 firstBurn = amount / 10;
        uint256 secondBurn = (amount - firstBurn) / 10;
        assertEq(beforeX - x.balanceOf(alice), amount);
        assertEq(x.balanceOf(address(pair)) - pairX, amount - firstBurn - secondBurn);
        assertEq(supply - x.totalSupply(), firstBurn + secondBurn);
        assertEq(x.balanceOf(address(router)), routerX, "donations cannot subsidize transfer taxes");
        assertEq(imd.balanceOf(address(router)), routerImd);
        assertEq(imd.balanceOf(alice) + 10 ether - beforeImd, pairImd - imd.balanceOf(address(pair)));
        assertGt(pairImd - imd.balanceOf(address(pair)), 0);
        assertEq(token.balanceOf(alice) - beforeMarg, margOut);
        assertEq(x.allowance(alice, address(router)), 0);
        assertEq(hook.noteCount(), noteCount + 1);
        T.Note memory n = hook.noteOf(bytes32(noteCount + 1));
        assertEq(n.author, alice);
        assertEq(n.x, address(x));
        assertEq(n.class, uint8(T.Class.Traded));
    }

    function test_TaxedInputSlippageRollsBackBurnsAllowancesAndPairReserves() public {
        x.transfer(address(router), 37e6);
        x.setMode(RouterBehaviorToken.Mode.Tax);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, 100e6);
        uint256 beforeX = x.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 supply = x.totalSupply();
        uint256 allowance = x.allowance(alice, address(router));
        uint256 pairX = x.balanceOf(address(pair));
        uint256 pairImd = imd.balanceOf(address(pair));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        for (uint256 i; i < 2; ++i) {
            t.minOut = i == 0 ? type(uint256).max : 1;
            vm.prank(alice);
            vm.expectRevert(MarginaliaRouter.Slippage.selector);
            router.tradeAndNote(t, p, 10 ether, i == 0 ? 1 : type(uint256).max, block.timestamp);
            assertEq(x.balanceOf(alice), beforeX);
            assertEq(imd.balanceOf(alice), beforeImd);
            assertEq(x.totalSupply(), supply);
            assertEq(x.allowance(alice, address(router)), allowance);
            assertEq(x.balanceOf(address(router)), 37e6);
            assertEq(imd.balanceOf(address(router)), 0);
            assertEq(x.balanceOf(address(pair)), pairX);
            assertEq(imd.balanceOf(address(pair)), pairImd);
            (uint112 after0, uint112 after1,) = pair.getReserves();
            assertEq(after0, r0);
            assertEq(after1, r1);
            assertEq(hook.noteCount(), 0);
            assertEq(_claims(address(hook), address(imd)), 0);
            assertEq(_claims(address(hook), address(token)), 0);
        }
    }

    function test_ZeroReceivedInputCannotSpendDonationsOrPostANote() public {
        x.transfer(address(router), 100e6);
        x.setMode(RouterBehaviorToken.Mode.FullTax);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, 100e6);
        uint256 beforeX = x.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 supply = x.totalSupply();
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(x.balanceOf(alice), beforeX);
        assertEq(imd.balanceOf(alice), beforeImd);
        assertEq(x.totalSupply(), supply);
        assertEq(x.balanceOf(address(router)), 100e6);
        assertEq(hook.noteCount(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SixDecimalInputIsChargedInRawUnits(uint256 amount) public {
        amount = bound(amount, 1, 1000e6);
        (MarginaliaRouter.XTrade memory t, T.NoteParams memory p) = _args(false, amount);
        uint256 beforeX = x.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.tradeAndNote(t, p, 10 ether, 1, block.timestamp);
        assertEq(beforeX - x.balanceOf(alice), amount);
        assertGt(imd.balanceOf(alice) + 10 ether, beforeImd);
        assertEq(token.balanceOf(alice) - beforeMarg, out);
        assertEq(x.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
    }
}
