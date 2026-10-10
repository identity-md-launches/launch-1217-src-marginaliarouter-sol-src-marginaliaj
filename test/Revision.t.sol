// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockV2Pair, MockV2Factory, PricedIntake} from "./Companions.t.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {MarginaliaImpls} from "../src/MarginaliaImpls.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

// The installed Forge supports this cheatcode; the vendored older Vm interface omits it.
interface RevisionColdVm {
    function cool(address target) external;
}

contract TaxedInput is ERC20 {
    constructor() ERC20("Taxed", "TAX") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = amount / 10;
            super._update(from, address(0), tax);
            amount -= tax;
        }
        super._update(from, to, amount);
    }
}

/// @dev The flash round-trip of finding 392cb896: inside one unlock, pump MARG with IMD, observe every note
/// held, dump the MARG back, and settle only the net IMD (the fees). No MARG is held across the call.
contract FlashObserver is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager private immutable manager;
    MarginaliaHook private immutable hook;

    constructor(IPoolManager m, MarginaliaHook h) {
        manager = m;
        hook = h;
    }

    function run(PoolKey memory key, bool imdIs0, uint256 imdIn, bytes32[] memory ids) external {
        manager.unlock(abi.encode(key, imdIs0, imdIn, ids));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool imdIs0, uint256 imdIn, bytes32[] memory ids) =
            abi.decode(data, (PoolKey, bool, uint256, bytes32[]));
        BalanceDelta d = manager.swap(
            key,
            SwapParams(
                imdIs0, -int256(imdIn), imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 margOut = imdIs0 ? d.amount1() : d.amount0();
        for (uint256 i; i < ids.length; ++i) {
            hook.observe(ids[i]);
        }
        manager.swap(
            key,
            SwapParams(
                !imdIs0, -int256(margOut), imdIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            ""
        );
        Currency imd = imdIs0 ? key.currency0 : key.currency1;
        require(
            manager.currencyDelta(address(this), imdIs0 ? key.currency1 : key.currency0) == 0, "marg held"
        );
        int256 owed = manager.currencyDelta(address(this), imd);
        require(owed < 0, "free round-trip");
        manager.sync(imd);
        IERC20(Currency.unwrap(imd)).transfer(address(manager), uint256(-owed));
        manager.settle();
        return "";
    }
}

contract RevisionTest is Fixture {
    using stdStorage for StdStorage;
    using PoolIdLibrary for PoolKey;
    PricedIntake private intake;
    MockV2Factory private v2Factory;

    function setUp() public {
        _setup();
        vm.etch(hook.INTAKE(), address(new PricedIntake()).code);
        intake = PricedIntake(hook.INTAKE());
        intake.setPrice(0.5 ether);
        vm.etch(router.V2_FACTORY(), address(new MockV2Factory()).code);
        v2Factory = MockV2Factory(router.V2_FACTORY());
    }

    function _thesis(address who) internal returns (bytes32 id) {
        (id,) = _note(who, _margNote(T.Side.Buy, 0, 0, "thesis: argued and cited"), 10 ether);
    }

    /// @dev `n` theses by rotating authors, a funded pot, and the week over.
    function _thesisWeek(uint256 n) internal returns (uint32 w, bytes32[] memory ids) {
        w = hook.week();
        ids = new bytes32[](n);
        address[3] memory authors = [alice, bob, alice];
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = _thesis(authors[i % 3]);
        }
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp(block.timestamp + 7 days);
    }

    function _att(bytes32[] memory ranked, uint16 panelSize)
        internal
        view
        returns (OracleAttestation.Attestation memory)
    {
        return OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle", ranked, block.timestamp)),
            chainId: block.chainid,
            questionHash: keccak256("q"),
            answerType: 5,
            answer: abi.encode(ranked),
            figure: 0,
            fromBlock: uint64(block.number - 100),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: bytes32(uint256(0xdef)),
            panelSize: panelSize,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _deliver(bytes32 reqId, bytes32[] memory ranked, uint16 panelSize) internal {
        vm.prank(address(intake));
        judge.onOracleResult(reqId, _att(ranked, panelSize), hex"01");
    }

    function _xTrade(uint8 kind, address pool, address tokenIn, uint256 amountIn)
        internal
        pure
        returns (MarginaliaRouter.XTrade memory t)
    {
        PoolKey memory none;
        t = MarginaliaRouter.XTrade(kind, none, false, pool, tokenIn, amountIn, 1);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i = 0; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length && ok; ++j) {
                ok = hay[i + j] == needle[j];
            }
            if (ok) return true;
        }
        return false;
    }

    function _resolve(bytes32 id) private {
        vm.warp(hook.horizonEnd(id));
        for (uint256 i; i < 3; ++i) {
            hook.observe(id);
            vm.roll(vm.getBlockNumber() + 25);
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
    }

    function testRevisionLeaderboardCannotPayAfterSweep() public {
        uint32 w = hook.week();
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        (bytes32 b,) = _note(bob, _margNote(T.Side.Buy, 11000, 1, "b"), 10 ether);
        vm.prank(alice);
        hook.fundPot(100 ether);
        _buy(bob, 1_500_000 ether);
        _resolve(a);
        _resolve(b);
        vm.warp((uint256(w) + 1) * 7 days + 1);
        vm.prank(alice);
        hook.claimLeaderboard(w);
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER());
        hook.sweep(1, w);
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimLeaderboard(w);
        vm.expectRevert(MarginaliaHook.NothingToSweep.selector);
        hook.sweep(1, w);
        assertEq(
            _claims(address(hook), address(imd)),
            hook.leaderboardPool(hook.week()) + hook.thesisPool(w) + hook.refundPool(hook.noteOf(a).day),
            "IMD claims cover live obligations"
        );
    }

    function testRevisionPendingJudgingCannotBeSwept() public {
        (uint32 w,) = _thesisWeek(1);
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER());
        judge.requestJudging(w);
        vm.expectRevert();
        hook.sweep(2, w);
    }

    function testRevisionJudgedPrizeCannotBeSwept() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(1);
        bytes32 req = judge.requestJudging(w);
        _deliver(req, ids, 7);
        uint256 prize = hook.thesisPool(w) / 2;
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER());
        vm.expectRevert();
        hook.sweep(2, w);
        uint256 before = imd.balanceOf(alice);
        judge.payJudged(w);
        assertEq(imd.balanceOf(alice) - before, prize);
    }

    function testRevisionRefundSurplusGoesToPrizes() public {
        uint32 d = hook.today();
        imd.transfer(address(treasury), 100_000 ether);
        treasury.drip();
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        hook.claimRefund(id);
        uint256 surplus = hook.refundPool(d);
        vm.warp((uint256(d) + 1) * 1 days + hook.SWEEP_AFTER());
        uint32 w = hook.week();
        uint256 before = hook.leaderboardPool(w) + hook.thesisPool(w);
        hook.sweep(0, d);
        assertEq(hook.refundPool(d), 0);
        assertEq(hook.leaderboardPool(w) + hook.thesisPool(w) - before, surplus);
    }

    function testRevisionPartialPotSaleRevertsAndRetainsClaims() public {
        for (uint256 i; i < 50; ++i) {
            (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20000, 7, "a"), 10 ether);
            vm.prank(alice);
            hook.retract(id, "out");
        }
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 1 ether));
        uint256 pot = hook.potMarg();
        uint256 claims = _claims(address(hook), address(token));
        vm.prank(address(judge));
        vm.expectRevert(MarginaliaHook.PartialFill.selector);
        hook.sellPotMarg(pot, 0);
        assertEq(hook.potMarg(), pot);
        assertEq(_claims(address(hook), address(token)), claims);
    }

    function testRevisionPartialDepositSaleRevertsAndRetainsDeposit() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 1 ether));
        uint256 deposit = hook.noteOf(id).deposit;
        uint256 claims = _claims(address(hook), address(token));
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.PartialFill.selector);
        hook.claimDeposit(id, true);
        assertEq(hook.noteOf(id).deposit, deposit);
        assertEq(_claims(address(hook), address(token)), claims);
    }

    function testRevisionAttestedClassNeedsAttestation() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11000, 1, "a");
        p.class = uint8(T.Class.Attested);
        (bytes32 id,) = _note(alice, p, 10 ether);
        assertEq(hook.noteOf(id).class, uint8(T.Class.Declared));
    }

    function testRevisionHoldBalanceIncludesPurchase() public {
        (bytes32 id, uint256 received) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        assertEq(hook.noteOf(id).postBalance, token.balanceOf(alice));
        _sell(alice, received);
        _buy(bob, 1_500_000 ether);
        _resolve(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
    }

    function testRevisionRetrySpendingIsBounded() public {
        (uint32 w,) = _thesisWeek(1);
        judge.requestJudging(w);
        vm.warp(block.timestamp + judge.REQUEST_TTL());
        judge.requestJudging(w);
        vm.warp(block.timestamp + judge.REQUEST_TTL());
        vm.expectRevert();
        judge.requestJudging(w);
        assertEq(intake.requests(), 2);
    }

    function testRevisionThresholdAppliesOnlyToFirstRequest() public {
        uint32 w = hook.week();
        _thesis(alice);
        vm.prank(alice);
        hook.fundPot(7 ether);
        vm.warp(block.timestamp + 7 days);
        judge.requestJudging(w);
        assertLt(hook.thesisPool(w), hook.JUDGE_THRESHOLD());
        vm.warp(block.timestamp + judge.REQUEST_TTL());
        judge.requestJudging(w);
        assertEq(intake.requests(), 2);
    }

    function testRevisionNoDataNotedSellForfeits() public {
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.sellWithNote(_margNote(T.Side.Sell, 9000, 90, "a"), 10_000 ether, 1, block.timestamp);
        bytes32 id = bytes32(hook.noteCount());
        uint256 deposit = hook.noteOf(id).deposit;
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(hook.noteOf(id).deposit, 0);
        assertEq(hook.potMarg(), deposit - deposit * hook.KEEPER_BPS() / 10_000);
    }

    function testRevisionTaxedV2InputUsesReceivedBudget() public {
        TaxedInput tax = new TaxedInput();
        MockV2Pair pair = new MockV2Pair(address(tax), address(imd));
        v2Factory.register(address(tax), address(imd), address(pair));
        tax.transfer(address(pair), 1000 ether);
        imd.transfer(address(pair), 1000 ether);
        tax.transfer(alice, 1000 ether);
        vm.prank(alice);
        tax.approve(address(router), type(uint256).max);
        T.NoteParams memory p = _margNote(T.Side.Sell, 0, 0, "taxed thesis");
        p.x = address(tax);
        MarginaliaRouter.XTrade memory trade = _xTrade(router.X_V2(), address(pair), address(tax), 100 ether);
        vm.prank(alice);
        router.tradeAndNote(trade, p, 10 ether, 1, block.timestamp);
        assertEq(tax.balanceOf(address(router)), 0);
        assertEq(hook.noteCount(), 1);
    }

    function testRevisionLateThesisNotExcludedByPostingOrder() public {
        uint32 w = hook.week();
        for (uint256 i; i < 256; ++i) {
            _thesis(bob);
        }
        bytes32 late = _thesis(alice);
        bytes32[] memory ids = hook.thesesOfWeek(w);
        assertEq(ids.length, 257);
        assertEq(ids[256], late);
        bytes memory body = bytes(judge.questionBody(w));
        // The panel reads the complete collection on chain instead of a first-200 allow-list.
        assertFalse(_contains(body, bytes("\"guards\"")));
        assertTrue(_contains(body, bytes("thesesOfWeek")));
        assertTrue(_contains(body, bytes(vm.toLowercase(vm.toString(address(hook))))));
        assertLe(body.length, 16384);
    }

    function testRevisionVenueMustDescribeBoundPool() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11000, 1, "a");
        p.x = address(imd); // a real pool id cannot be reused for another subject
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp);
        p.x = address(token);
        p.venue.xIsToken0 = !margIs0;
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp);
        p.venue.xIsToken0 = margIs0;
        p.venue.quote = address(token);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp);
        p.venue.quote = address(imd);
        p.venue.ref = bytes32(uint256(123));
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp);
    }

    function testRevisionThinPoolCannotPostOrObserveScoredCalls() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 100 ether));
        vm.warp(hook.horizonEnd(id));
        vm.expectRevert(MarginaliaHook.InvalidPool.selector);
        hook.observe(id);
        T.NoteParams memory p = _margNote(T.Side.Buy, 11000, 1, "a");
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 1 ether, 1, block.timestamp);
    }

    function testRevisionNotedSellRecordsPostTradeBalance() public {
        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "a");
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.sellWithNote(p, 100 ether, 1, block.timestamp);
        assertEq(hook.noteOf(bytes32(hook.noteCount())).postBalance, token.balanceOf(alice));
    }

    function testRevisionDepositMinimumRollsBackAndCanClaimMarg() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.Slippage.selector);
        hook.claimDeposit(id, true, 100 ether);
        assertEq(hook.noteOf(id).deposit, deposit);
        vm.prank(alice);
        hook.claimDeposit(id, false, 0);
        assertEq(hook.noteOf(id).deposit, 0);
    }

    function testRevisionExpiredUnansweredPrizeCanRollAndRejectsLateCallback() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(1);
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER());
        bytes32 req = judge.requestJudging(w);
        vm.warp(block.timestamp + judge.REQUEST_TTL());
        uint256 prize = hook.thesisPool(w);
        hook.sweep(2, w);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()), prize);
        vm.prank(address(intake));
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.onOracleResult(req, _att(ids, 7), hex"01");
    }

    function testRevisionPotConversionsAreBoundedDailyChunks() public {
        for (uint256 i; i < 50; ++i) {
            (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20000, 7, "a"), 10 ether);
            vm.prank(alice);
            hook.retract(id, "out");
        }
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 2000 ether));
        uint256 before = hook.potMarg();
        uint256 out = judge.convertForfeits();
        assertGt(out, 0);
        assertGt(hook.potMarg(), 0);
        uint256 spent = before - hook.potMarg();
        assertApproxEqAbs(spent, 20 ether, 0.01 ether);
        vm.expectRevert(MarginaliaJudge.AlreadyConverted.selector);
        judge.convertForfeits();
        vm.warp(block.timestamp + 1 days);
        judge.convertForfeits();
        assertEq(hook.potMarg(), 0);
    }

    function testRevisionCallbackFitsColdStipendWithEoaSignature() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(3);
        uint256 signingKey = uint256(keccak256("revision oracle test signer"));
        address signer = vm.addr(signingKey);
        // The fixture uses ERC-1271; exercise the mainnet EOA verification path with a test signer.
        stdstore.target(address(judge)).sig("oracleSigner()").checked_write(signer);
        bytes32 req = judge.requestJudging(w);
        OracleAttestation.Attestation memory att = _att(ids, 7);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(signingKey, judge.attestationDigest(att));
        bytes memory signature = abi.encodePacked(r, sigS, v);
        RevisionColdVm(address(vm)).cool(address(judge));
        RevisionColdVm(address(vm)).cool(address(hook));
        RevisionColdVm(address(vm)).cool(signer);
        RevisionColdVm(address(vm)).cool(address(intake));
        vm.prank(address(intake));
        judge.onOracleResult{gas: 200_000}(req, att, signature);
        assertTrue(judge.judgedSet(w));
        bytes32[3] memory top = judge.judgedOf(w);
        assertEq(top[0], ids[0]);
        assertEq(top[1], ids[1]);
        assertEq(top[2], ids[2]);
    }

    function testRevisionEachCodelessImplementationIsRefused() public {
        address[3] memory implementations =
            [MarginaliaImpls.ROUTER_IMPL, MarginaliaImpls.JUDGE_IMPL, MarginaliaImpls.TREASURY_IMPL];
        for (uint256 i; i < 3; ++i) {
            bytes memory runtime = implementations[i].code;
            vm.etch(implementations[i], "");
            // Configuration is checked before hook flags: an unmined address still gets this precise error.
            vm.expectRevert(bytes("configuration required"));
            new MarginaliaHook(manager, address(token), address(this));
            vm.etch(implementations[i], runtime);
        }
    }

    function testRevisionCanonicalAuthorCreatedV4MarketCannotScore() public {
        MockERC20 arbitraryX = new MockERC20("Author X", "X", 1_000_000 ether);
        (address c0, address c1) = address(arbitraryX) < address(imd)
            ? (address(arbitraryX), address(imd))
            : (address(imd), address(arbitraryX));
        PoolKey memory ownKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(ownKey, uint160(1 << 96));
        arbitraryX.transfer(address(liquidity), 100_000 ether);
        liquidity.add(ownKey, -6000, 6000, 10_000 ether);
        T.NoteParams memory p = _margNote(T.Side.Buy, type(uint32).max, 1, "self-priced X");
        p.x = address(arbitraryX);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(ownKey.toId()), address(imd), c0 == p.x);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp);
        assertEq(hook.noteCount(), 0);
        // The same token remains tradable with a thesis about the trade.
        p.targetBps = 0;
        p.horizonDays = 0;
        MarginaliaRouter.XTrade memory trade = MarginaliaRouter.XTrade(
            router.X_V4(), ownKey, c0 == address(imd), address(0), address(0), 1 ether, 1
        );
        vm.prank(alice);
        router.tradeAndNote(trade, p, 10 ether, 1, block.timestamp);
        assertEq(uint8(hook.noteOf(bytes32(uint256(1))).status), uint8(T.Status.ThesisOpen));
        assertEq(hook.noteOf(bytes32(uint256(1))).class, uint8(T.Class.Traded));
    }

    // ---------------------------------------------------------------- finding 392cb896: flash observations

    /// @dev Three sybil +10% calls on a pool 100x the depth floor, the pot funded, the price never moving.
    function _flashSetup() private returns (uint32 w, bytes32[] memory ids, address[3] memory sybils) {
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 100_000 ether));
        sybils = [alice, bob, carol];
        imd.transfer(carol, 1_000 ether);
        vm.prank(carol);
        imd.approve(address(router), type(uint256).max);
        w = hook.week();
        vm.prank(alice);
        hook.fundPot(20_000 ether);
        ids = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            (ids[i],) = _note(sybils[i], _margNote(T.Side.Buy, 11000, 1, "MARG +10% tomorrow"), 10 ether);
        }
    }

    function testRevisionFlashObservationReadsTheBlockOpenPrice() public {
        (uint32 w, bytes32[] memory ids, address[3] memory sybils) = _flashSetup();
        FlashObserver attacker = new FlashObserver(manager, hook);
        imd.transfer(address(attacker), 10_000 ether);
        vm.warp(hook.horizonEnd(ids[0]));
        for (uint256 i; i < 3; ++i) {
            vm.roll(vm.getBlockNumber() + 25);
            uint256 open = hook.margPriceInImd();
            attacker.run(key, !margIs0, 5_900 ether, ids);
            // Inside the round-trip the spot was +12%, but the observation stored the block's opening price.
            assertEq(hook.blockPrice(), open);
            assertLt(open * 10_000, 1.01e18 * 10_000);
        }
        vm.warp(hook.horizonEnd(ids[0]) + hook.SETTLE_WINDOW() + 1);
        for (uint256 i; i < 3; ++i) {
            hook.settle(ids[i]);
            assertEq(uint8(hook.noteOf(ids[i]).status), uint8(T.Status.Wrong));
        }
        vm.warp(block.timestamp + 7 days);
        for (uint256 i; i < 3; ++i) {
            assertEq(hook.leaderboardShare(w, sybils[i]), 0);
            vm.prank(sybils[i]);
            vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
            hook.claimLeaderboard(w);
        }
    }

    function testRevisionObservationIgnoresASwapLaterInTheBlock() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        uint256 open = hook.margPriceInImd();
        vm.warp(hook.horizonEnd(id));
        vm.roll(vm.getBlockNumber() + 1);
        // No swap yet this block: the observation is the spot, which is the block-open price.
        hook.observe(id);
        _buy(bob, 1_500_000 ether);
        assertGt(hook.margPriceInImd(), 1.1e18);
        assertEq(hook.blockPrice(), open);
        // A second observation in the same block is refused by the gap anyway; after the gap, the pump counts
        // only if it is still there, i.e. held across the gap.
        vm.roll(vm.getBlockNumber() + 25);
        hook.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        hook.observe(id);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
    }

    function testRevisionFlashMoveBeforePostingCannotSetThePostPrice() public {
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether - 100_000 ether));
        uint256 open = hook.margPriceInImd();
        // Same block: dump MARG, post a +10% buy at the depressed spot, buy the MARG back.
        uint256 got = _sell(bob, 6_000 ether);
        uint256 depressed = hook.margPriceInImd();
        assertLt(depressed * 10_000, open * 9_000);
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        _buy(bob, got);
        // The post price is the block-open price, not the one the dump set.
        assertGe(hook.noteOf(id).postPrice, open);
        assertGt(hook.noteOf(id).postPrice, depressed);
        // The mirror image for a sell: pump, then post a -10% sell, and the post price is the open price.
        vm.roll(vm.getBlockNumber() + 1);
        open = hook.margPriceInImd();
        _buy(bob, 6_000 ether);
        assertGt(hook.margPriceInImd() * 10_000, open * 11_000);
        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "s");
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        router.sellWithNote(p, 100 ether, 1, block.timestamp);
        vm.stopPrank();
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertLe(n.postPrice, open);
        // And the deposit is sized at the lower price, so the pump could not shrink it.
        assertGe(n.deposit, hook.DEPOSIT() * 1e18 / open - 1);
    }

    function testRevisionHeldMoveStillSettlesRight() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11000, 1, "a"), 10 ether);
        _buy(bob, 1_500_000 ether);
        vm.warp(hook.horizonEnd(id));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.blockPrice(), hook.margPriceInImd());
        _resolve(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
    }
}
