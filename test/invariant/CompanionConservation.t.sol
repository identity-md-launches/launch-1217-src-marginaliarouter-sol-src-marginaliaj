// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StrictOracleSigner, AdversarialIntake} from "../security/JudgeAdversarial.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaJudge} from "src/MarginaliaJudge.sol";
import {MarginaliaTreasury} from "src/MarginaliaTreasury.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @dev All value moves through the real companions, hook and local v4 PoolManager.
/// Time only moves forwards. Every caught failure has an explicit expected cause.
contract CompanionHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    MarginaliaHook public hook;
    MarginaliaRouter public router;
    MarginaliaJudge public judge;
    MarginaliaTreasury public treasury;
    IERC20 public imd;
    IERC20 public marg;
    address[3] public actors;
    uint256 private signerKey;
    uint32[] public weeksTouched;
    uint32[] public daysTouched;
    mapping(uint32 => bool) private seenWeek;
    mapping(uint32 => bool) private seenDay;
    mapping(uint32 => uint256) public paymentCount;
    mapping(uint32 => bytes32) public acceptedOracleId;
    mapping(uint32 => uint256) public dripCount;
    mapping(uint32 => uint256) public requestCount;
    mapping(uint32 => uint256) public conversionCount;
    uint256 public donatedTreasury;
    uint256 public dripped;
    uint256 public donatedRouterImd;
    uint256 public donatedRouterMarg;
    uint256 public donatedJudge;
    uint256 public oracleSpent;
    uint256 public payouts;
    uint256 public notesPosted;
    uint256 public deliveries;
    uint256 public conversions;

    constructor(MarginaliaHook h, address[3] memory users, uint256 key) {
        hook = h;
        router = h.router();
        judge = h.judge();
        treasury = h.treasury();
        imd = IERC20(h.imd());
        marg = IERC20(h.token());
        actors = users;
        signerKey = key;
        _touch();
    }

    function _touch() private {
        uint32 d = hook.today();
        uint32 w = hook.week();
        if (!seenDay[d]) {
            seenDay[d] = true;
            daysTouched.push(d);
        }
        if (!seenWeek[w]) {
            seenWeek[w] = true;
            weeksTouched.push(w);
        }
    }

    function weekCount() external view returns (uint256) {
        return weeksTouched.length;
    }

    function dayCount() external view returns (uint256) {
        return daysTouched.length;
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 8 days));
        _touch();
    }

    function donate(uint8 destination, uint256 amountSeed, uint8 actorSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        destination %= 4;
        vm.prank(actor);
        if (destination == 0) {
            imd.transfer(address(treasury), amount);
            donatedTreasury += amount;
        } else if (destination == 1) {
            imd.transfer(address(router), amount);
            donatedRouterImd += amount;
        } else if (destination == 2) {
            marg.transfer(address(router), amount);
            donatedRouterMarg += amount;
        } else {
            imd.transfer(address(judge), amount);
            donatedJudge += amount;
        }
    }

    function note(uint256 amountSeed, uint8 actorSeed, bool sell) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 2 ether, 50 ether);
        T.NoteParams memory p;
        p.x = address(marg);
        p.side = sell ? T.Side.Sell : T.Side.Buy;
        p.class = uint8(T.Class.Declared);
        p.text = "bounded invariant thesis";
        uint256 beforeImd = imd.balanceOf(actor);
        uint256 beforeMarg = marg.balanceOf(actor);
        vm.prank(actor);
        uint256 out = sell
            ? router.sellWithNote(p, amount, 1, block.timestamp)
            : router.note(p, amount, 1, block.timestamp);
        if (sell) {
            assertEq(beforeMarg - marg.balanceOf(actor), amount);
            assertEq(imd.balanceOf(actor) - beforeImd, out);
        } else {
            assertEq(beforeImd - imd.balanceOf(actor), amount);
            assertEq(marg.balanceOf(actor) - beforeMarg, out);
        }
        ++notesPosted;
        assertEq(hook.noteOf(bytes32(notesPosted)).author, actor);
    }

    function drip(uint8 actorSeed) public {
        uint256 held = imd.balanceOf(address(treasury));
        uint32 day = hook.today();
        vm.prank(actors[actorSeed % 3]);
        if (day == treasury.lastDripDay()) {
            vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
            treasury.drip();
            assertEq(imd.balanceOf(address(treasury)), held);
        } else if (held < 50) {
            vm.expectRevert(MarginaliaTreasury.NothingToDrip.selector);
            treasury.drip();
            assertEq(imd.balanceOf(address(treasury)), held);
        } else {
            treasury.drip();
            uint256 moved = held - imd.balanceOf(address(treasury));
            assertLe(moved * 50, held);
            assertLt(held - moved * 50, 50);
            dripped += moved;
            assertEq(++dripCount[day], 1, "multiple successful drips in one UTC day");
        }
    }

    function request(uint256 epochSeed, uint8 actorSeed) public {
        uint32 w = weeksTouched[epochSeed % weeksTouched.length];
        bytes32 old = judge.requestOf(w);
        bytes4 expected;
        if (w >= hook.week()) {
            expected = MarginaliaJudge.DayNotOver.selector;
        } else if (judge.judgedSet(w)) {
            expected = MarginaliaJudge.AlreadyJudged.selector;
        } else if (requestCount[w] == 2) {
            expected = MarginaliaJudge.AttemptsExhausted.selector;
        } else if (old != bytes32(0) && block.timestamp < uint256(judge.requestedAt(w)) + judge.REQUEST_TTL())
        {
            expected = MarginaliaJudge.AlreadyRequested.selector;
        } else if (hook.thesesOfWeek(w).length == 0) {
            expected = MarginaliaJudge.NoNotes.selector;
        } else if ((requestCount[w] == 0 && hook.thesisPool(w) < 2 ether) || hook.thesisPool(w) < 0.5 ether) {
            expected = MarginaliaHook.PotTooSmall.selector;
        }
        uint256 beforePool = hook.thesisPool(w);
        uint256 beforeJudge = imd.balanceOf(address(judge));
        uint64 beforeTime = judge.requestedAt(w);
        vm.prank(actors[actorSeed % 3]);
        if (expected != bytes4(0)) {
            vm.expectRevert(expected);
            judge.requestJudging(w);
            assertEq(judge.requestOf(w), old);
            assertEq(judge.requestedAt(w), beforeTime);
            assertEq(hook.thesisPool(w), beforePool);
        } else {
            bytes32 id = judge.requestJudging(w);
            assertNotEq(id, old);
            assertEq(beforePool - hook.thesisPool(w), 0.5 ether);
            oracleSpent += 0.5 ether;
            ++requestCount[w];
        }
        assertEq(judge.attempts(w), requestCount[w]);
        assertEq(imd.balanceOf(address(judge)), beforeJudge, "purchase must not spend donated IMD");
    }

    function deliver(uint256 epochSeed, bool empty) public {
        uint32 w = weeksTouched[epochSeed % weeksTouched.length];
        bytes32 req = judge.requestOf(w);
        if (req == bytes32(0) || judge.judgedSet(w)) return;
        bytes32[] memory candidates = hook.thesesOfWeek(w);
        uint256 n = empty ? 0 : (candidates.length < 3 ? candidates.length : 3);
        bytes32[] memory ranked = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ranked[i] = candidates[n - i - 1];
        }
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("handler oracle", req));
        a.chainId = block.chainid;
        a.questionHash = keccak256(bytes(judge.questionBody(w)));
        a.answerType = 5;
        a.answer = abi.encode(ranked);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, judge.attestationDigest(a));
        if (block.timestamp >= uint256(judge.requestedAt(w)) + judge.REQUEST_TTL()) {
            vm.prank(hook.INTAKE());
            vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
            judge.onOracleResult(req, a, abi.encodePacked(r, s, v));
            assertFalse(judge.judgedSet(w));
            assertFalse(judge.consumed(a.requestId));
            assertEq(judge.requestOf(w), req);
            return;
        }
        vm.prank(hook.INTAKE());
        judge.onOracleResult(req, a, abi.encodePacked(r, s, v));
        acceptedOracleId[w] = a.requestId;
        ++deliveries;
        bytes32[3] memory top = judge.judgedOf(w);
        for (uint256 i; i < 3; ++i) {
            assertEq(top[i], i < n ? ranked[i] : bytes32(0));
        }
    }

    function pay(uint256 epochSeed, uint8 actorSeed) public {
        uint32 w = weeksTouched[epochSeed % weeksTouched.length];
        uint256 totalBefore;
        for (uint256 i; i < 3; ++i) {
            totalBefore += imd.balanceOf(actors[i]);
        }
        uint256 pot = hook.thesisPool(w);
        bytes4 expected;
        if (!judge.judgedSet(w)) expected = MarginaliaJudge.NotJudged.selector;
        else if (judge.paid(w)) expected = MarginaliaJudge.AlreadyPaid.selector;
        vm.prank(actors[actorSeed % 3]);
        if (expected != bytes4(0)) {
            vm.expectRevert(expected);
            judge.payJudged(w);
            assertEq(hook.thesisPool(w), pot);
        } else {
            judge.payJudged(w);
            assertEq(++paymentCount[w], 1, "a week was paid more than once");
            uint256 totalAfter;
            for (uint256 i; i < 3; ++i) {
                totalAfter += imd.balanceOf(actors[i]);
            }
            uint256 moved = totalAfter - totalBefore;
            assertLe(moved, pot);
            payouts += moved;
            assertEq(hook.thesisPool(w), 0);
        }
    }

    function forfeit(uint256 noteSeed) public {
        if (notesPosted == 0) return;
        bytes32 id = bytes32(bound(noteSeed, 1, notesPosted));
        T.Note memory n = hook.noteOf(id);
        if (n.status != T.Status.ThesisOpen || block.timestamp <= uint256(n.postedAt) + hook.THESIS_GRACE()) {
            return;
        }
        hook.settleThesis(id);
        assertEq(hook.noteOf(id).deposit, 0);
    }

    function convert(uint8 actorSeed) public {
        uint256 old = hook.potMarg();
        uint32 day = hook.today();
        if (old == 0) {
            vm.prank(actors[actorSeed % 3]);
            assertEq(judge.convertForfeits(), 0);
        } else if (conversionCount[day] != 0) {
            vm.prank(actors[actorSeed % 3]);
            vm.expectRevert(MarginaliaJudge.AlreadyConverted.selector);
            judge.convertForfeits();
            assertEq(hook.potMarg(), old);
        } else {
            IPoolManager manager = hook.poolManager();
            PoolKey memory key = hook.getPoolKey();
            (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
            uint256 depthLiquidity = manager.getLiquidity(key.toId());
            uint256 beforeMarg = manager.balanceOf(address(hook), uint256(uint160(address(marg))));
            uint256 beforeImd = manager.balanceOf(address(hook), uint256(uint160(address(imd))));
            vm.prank(actors[actorSeed % 3]);
            uint256 out = judge.convertForfeits();
            assertGt(out, 0);
            uint256 sold = old - hook.potMarg();
            assertGt(sold, 0);
            // At most 1% of pre-swap virtual MARG reserves; avoid reimplementing the rounded cap.
            if (Currency.unwrap(key.currency0) == address(marg)) {
                assertLe(sold * 100 * uint256(sqrtP), depthLiquidity * (1 << 96));
            } else {
                assertLe(sold * 100 * (1 << 96), depthLiquidity * uint256(sqrtP));
            }
            assertEq(beforeMarg - manager.balanceOf(address(hook), uint256(uint160(address(marg)))), sold);
            assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))) - beforeImd, out);
            assertEq(++conversionCount[day], 1);
            ++conversions;
        }
        assertEq(judge.converted(day), conversionCount[day] == 1);
    }

    function unauthorizedCallback(uint8 actorSeed) public {
        uint256 beforeImd = imd.balanceOf(address(router));
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1, 1, "");
        assertEq(imd.balanceOf(address(router)), beforeImd);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CompanionConservationInvariantTest is Fixture {
    CompanionHandler handler;

    function setUp() public {
        _setup();
        (address signer, uint256 signerKey) = makeAddrAndKey("invariant signer");
        vm.etch(hook.ORACLE_SIGNER(), address(new StrictOracleSigner(signer)).code);
        vm.etch(hook.INTAKE(), address(new AdversarialIntake()).code);
        AdversarialIntake(hook.INTAKE()).configure(0.5 ether, false, false);
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            imd.transfer(actors[i], 1_000_000 ether);
            token.transfer(actors[i], 1_000_000 ether);
            vm.startPrank(actors[i]);
            imd.approve(address(router), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        handler = new CompanionHandler(hook, actors, signerKey);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.note.selector;
        selectors[3] = handler.drip.selector;
        selectors[4] = handler.request.selector;
        selectors[5] = handler.deliver.selector;
        selectors[6] = handler.pay.selector;
        selectors[7] = handler.forfeit.selector;
        selectors[8] = handler.convert.selector;
        selectors[9] = handler.unauthorizedCallback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        // Reach every custody stage before random exploration; the campaign cannot pass on empty state.
        handler.note(10 ether, 0, false);
        handler.note(10 ether, 1, false);
        handler.note(10 ether, 2, true);
        handler.donate(0, 1000 ether, 0);
        handler.drip(1);
        handler.advance(7 days + 1);
        handler.request(0, 2);
        handler.deliver(0, false);
        handler.pay(0, 1);
        handler.forfeit(1);
        handler.convert(2);
        handler.donate(1, 7 ether, 0);
        handler.donate(2, 9 ether, 1);
        handler.donate(3, 11 ether, 2);
    }

    function invariant_TreasuryDonationsEqualHeldPlusDripped() public view {
        assertEq(imd.balanceOf(address(treasury)) + handler.dripped(), handler.donatedTreasury());
        assertEq(imd.allowance(address(treasury), address(hook)), 0);
        assertEq(address(treasury.hook()), address(hook));
        for (uint256 i; i < handler.dayCount(); ++i) {
            assertLe(handler.dripCount(handler.daysTouched(i)), 1);
        }
    }

    function invariant_RouterAndJudgeRetainOnlyUnsolicitedDonations() public view {
        assertEq(imd.balanceOf(address(router)), handler.donatedRouterImd());
        assertEq(token.balanceOf(address(router)), handler.donatedRouterMarg());
        assertEq(imd.balanceOf(address(judge)), handler.donatedJudge());
        assertEq(token.balanceOf(address(judge)), 0);
        assertEq(imd.allowance(address(judge), hook.INTAKE()), 0);
        assertEq(imd.balanceOf(hook.INTAKE()), handler.oracleSpent());
        assertEq(hook.noteCount(), handler.notesPosted());
        assertEq(address(router.manager()), address(manager));
        assertEq(address(router.hook()), address(hook));
        assertEq(address(judge.hook()), address(hook));
    }

    function invariant_HookClaimsBackEveryImdPoolAndMargDeposit() public view {
        uint256 imdOwed;
        for (uint256 i; i < handler.weekCount(); ++i) {
            uint32 w = handler.weeksTouched(i);
            imdOwed += hook.leaderboardPool(w) + hook.thesisPool(w);
        }
        for (uint256 i; i < handler.dayCount(); ++i) {
            imdOwed += hook.refundPool(handler.daysTouched(i));
        }
        assertEq(_claims(address(hook), address(imd)), imdOwed);
        uint256 margOwed = hook.potMarg();
        for (uint256 i = 1; i <= hook.noteCount(); ++i) {
            margOwed += hook.noteOf(bytes32(i)).deposit;
        }
        assertEq(_claims(address(hook), address(token)), margOwed);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function invariant_JudgmentAndPaymentNeverReopen() public view {
        assertGt(handler.oracleSpent(), 0);
        assertGt(handler.payouts(), 0);
        assertGt(handler.deliveries(), 0);
        assertGt(handler.conversions(), 0);
        uint256 requests;
        for (uint256 i; i < handler.weekCount(); ++i) {
            uint32 w = handler.weeksTouched(i);
            assertEq(judge.attempts(w), handler.requestCount(w));
            assertLe(handler.requestCount(w), 2);
            requests += handler.requestCount(w);
            assertEq(judge.paid(w), handler.paymentCount(w) == 1);
            assertEq(hook.judgedPaid(w), judge.paid(w));
            assertLe(handler.paymentCount(w), 1);
            if (judge.paid(w)) assertTrue(judge.judgedSet(w));
            bytes32 accepted = handler.acceptedOracleId(w);
            assertEq(judge.judgedSet(w), accepted != bytes32(0));
            if (accepted != bytes32(0)) assertTrue(judge.consumed(accepted));
        }
        assertEq(handler.oracleSpent(), requests * 0.5 ether);
        uint256 conversions;
        for (uint256 i; i < handler.dayCount(); ++i) {
            uint32 d = handler.daysTouched(i);
            assertLe(handler.conversionCount(d), 1);
            assertEq(judge.converted(d), handler.conversionCount(d) == 1);
            conversions += handler.conversionCount(d);
        }
        assertEq(handler.conversions(), conversions);
    }

    function test_HandlerExercisesExpiredDeliveryRetryExhaustionAndDailyConversionLimit() public {
        // The setup converted one forfeit today. Another forfeit must wait for the next UTC day.
        handler.forfeit(2);
        handler.convert(0);
        handler.advance(1 days);
        handler.convert(1);
        handler.note(10 ether, 0, false);
        handler.donate(0, 1000 ether, 0);
        handler.drip(1);
        handler.advance(7 days);
        handler.request(1, 0);
        handler.advance(3 days);
        handler.deliver(1, false);
        handler.request(1, 1);
        handler.advance(3 days);
        handler.deliver(1, false);
        handler.request(1, 2);
        assertEq(handler.requestCount(handler.weeksTouched(1)), 2);
        assertEq(handler.conversions(), 2);
        invariant_TreasuryDonationsEqualHeldPlusDripped();
        invariant_RouterAndJudgeRetainOnlyUnsolicitedDonations();
        invariant_HookClaimsBackEveryImdPoolAndMargDeposit();
        invariant_JudgmentAndPaymentNeverReopen();
    }
}
