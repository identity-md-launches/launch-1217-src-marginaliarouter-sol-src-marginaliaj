// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIntake} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract LifecycleTest is Fixture {
    function setUp() public {
        _setup();
    }

    function testFlagsAndBinding() public view {
        assertTrue(HookFlags.matches(address(hook), HookFlags.MARGINALIA));
        assertTrue(hook.initialized());
        assertEq(hook.imd(), address(imd));
        assertEq(address(hook.router()), address(router));
        assertEq(hook.margPriceInImd(), 1e18);
    }

    function testCallbackSelectorPinned() public view {
        // Same signature as the protocol's reference consumer (AskOracle), whose documented selector is 0x510379c7.
        assertEq(judge.onOracleResult.selector, bytes4(0x510379c7));
    }

    function testPlainBuyTakesNothing() public {
        uint256 pot = hook.potImd(hook.today());
        uint256 out = _buy(alice, 10 ether);
        assertGt(out, 9 ether);
        assertEq(hook.potImd(hook.today()), pot);
        assertEq(hook.noteCount(), 0);
    }

    function testNotedBuyTakesStampAndDeposit() public {
        uint256 margBefore = token.balanceOf(alice);
        (bytes32 id, uint256 received) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x: fee pot compounding"), 10 ether);
        T.Note memory n = hook.noteOf(id);
        assertEq(n.author, alice);
        assertEq(uint8(n.status), uint8(T.Status.Open));
        assertEq(uint8(n.class), uint8(T.Class.Declared));
        assertApproxEqRel(n.deposit, 0.5 ether, 0.02e18); // ~0.5 IMD of MARG at ~1:1
        assertApproxEqRel(n.postPrice, 1e18, 0.02e18);
        assertEq(hook.potImd(hook.today()), hook.STAMP());
        assertEq(_claims(address(hook), address(imd)), hook.STAMP());
        assertEq(_claims(address(hook), address(token)), n.deposit);
        assertEq(token.balanceOf(alice) - margBefore, received);
        assertGt(received, 9 ether);
    }

    function testNoteTooSmall() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "tiny");
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 0.15 ether, 1, block.timestamp + 1);
    }

    function testUpOnlyIsRefused() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 10_500, 7, "up");
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, 10 ether, 1, block.timestamp + 1);
    }

    function testQuietSellPaysThreePercent() public {
        uint256 potBefore = hook.potImd(hook.today());
        uint256 out = _sell(bob, 100 ether);
        uint256 fee = hook.potImd(hook.today()) - potBefore;
        // fee = 3% of what the pool paid out; the seller received pool output minus fee
        assertApproxEqRel(fee, (out + fee) * 300 / 10_000, 0.001e18);
        assertEq(_claims(address(hook), address(imd)), fee);
    }

    function testNotedSellPaysOnePercentPlusStamp() public {
        vm.prank(bob);
        token.approve(address(router), type(uint256).max);
        uint256 potBefore = hook.potImd(hook.today());
        uint256 claimsBefore = _claims(address(hook), address(token));
        T.NoteParams memory p = _margNote(T.Side.Sell, 7000, 14, "MARG -30%: airdrop supply still unwinding");
        vm.prank(bob);
        uint256 out = router.sellWithNote(p, 100 ether, 1, block.timestamp + 1);
        bytes32 id = bytes32(hook.noteCount());
        T.Note memory n = hook.noteOf(id);
        assertEq(n.author, bob);
        assertEq(uint8(n.side), uint8(T.Side.Sell));
        assertApproxEqRel(n.deposit, 0.5 ether, 0.02e18);
        assertEq(_claims(address(hook), address(token)) - claimsBefore, n.deposit);
        uint256 taken = hook.potImd(hook.today()) - potBefore;
        // the pool paid out (out + taken); 1% of that plus the 0.1 stamp went to the pot
        assertApproxEqRel(taken - hook.STAMP(), (out + taken) * 100 / 10_000, 0.001e18);
        // cheaper than the quiet path on the same size
        uint256 potMid = hook.potImd(hook.today());
        _sell(bob, 100 ether);
        uint256 quiet = hook.potImd(hook.today()) - potMid;
        assertGt(quiet, taken);
    }

    function testRightCallReturnsDepositAsImd() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10% in a day: the airdrop sells are done"), 10 ether);
        // bob pushes the price up more than 10%
        _buy(bob, 1_500_000 ether);
        assertGt(hook.margPriceInImd(), 1.1e18);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
        }
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settle(id);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        T.Note memory n = hook.noteOf(id);
        assertEq(uint8(n.status), uint8(T.Status.Right));
        MarginaliaHook.Record memory r = hook.recordOf(alice);
        assertEq(r.right, 1);
        assertGt(r.score, 0);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id, true);
        assertGt(imd.balanceOf(alice), imdBefore);
        assertEq(_claims(address(hook), address(token)), 0);
        assertEq(hook.noteOf(id).deposit, 0);
    }

    function testWrongCallForfeitsWithKeeperReward() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 15_000, 1, "+50%: no"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(token.balanceOf(carol), deposit * 200 / 10_000);
        assertEq(hook.potMarg(), deposit - deposit * 200 / 10_000);
        assertLt(hook.recordOf(alice).score, 0);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimDeposit(id, false);
    }

    function testSellingEarlyBreaksTheCall() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        _sell(alice, token.balanceOf(alice) / 2);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(hook.recordOf(alice).broken, 1);
    }

    function testNoDataRefunds() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidNoData));
        assertEq(hook.recordOf(alice).score, 0);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id, false);
        assertEq(token.balanceOf(alice) - before, deposit);
    }

    function testRetract() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.retract(id, "not mine");
        vm.prank(alice);
        hook.retract(id, "thesis dead: the dev sold");
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Retracted));
        assertEq(hook.potMarg(), deposit);
        assertLt(hook.recordOf(alice).score, 0);
        assertEq(hook.recordOf(alice).retracted, 1);
    }

    function testThesisParentChild() public {
        T.NoteParams memory thesis = _margNote(T.Side.Buy, 0, 0, "Privacy re-rates after the next exploit: citations...");
        (bytes32 tid,) = _note(alice, thesis, 10 ether);
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisOpen));
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child call");
        child.parentId = tid;
        (bytes32 cid,) = _note(alice, child, 10 ether);
        assertEq(hook.noteOf(tid).children, 1);
        vm.warp(hook.horizonEnd(cid) + hook.SETTLE_WINDOW() + 1);
        hook.settle(cid); // no data, but it resolved
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisClosed));
        vm.prank(alice);
        hook.claimDeposit(tid, false);
    }

    function testThesisWithoutChildForfeits() public {
        (bytes32 tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "essay"), 10 ether);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settleThesis(tid);
        vm.warp(block.timestamp + 8 days);
        hook.settleThesis(tid);
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisForfeited));
        assertGt(hook.potMarg(), 0);
    }

    function testTreasuryDrip() public {
        imd.transfer(address(treasury), 1000 ether);
        treasury.drip();
        assertEq(hook.potImd(hook.today()), 20 ether);
        vm.expectRevert(MarginaliaHook.PotTooSmall.selector);
        hook.fundPot(0);
        vm.expectRevert();
        treasury.drip();
    }

    function testJudgingFlow() public {
        uint32 day = hook.today();
        (bytes32 a1,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "argued well"), 10 ether);
        (bytes32 b1,) = _note(bob, _margNote(T.Side.Buy, 20_000, 7, "argued less well"), 10 ether);
        vm.prank(alice);
        hook.fundPot(5 ether);
        assertEq(hook.notesOfDay(day).length, 2);
        vm.expectRevert();
        judge.requestJudging(day); // day not over
        vm.warp(block.timestamp + 1 days);
        bytes32 reqId = judge.requestJudging(day);
        MockIntake intake = MockIntake(hook.INTAKE());
        assertEq(intake.requests(), 1);
        assertEq(intake.lastTarget(), address(judge));
        assertEq(intake.lastSelector(), judge.onOracleResult.selector);
        assertEq(hook.potImd(day), 5 ether + 2 * hook.STAMP() - 0.5 ether);
        // The panel answers: bob first, then alice.
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = b1;
        ranked[1] = a1;
        OracleAttestation.Attestation memory att = OracleAttestation.Attestation({
            requestId: bytes32(uint256(0xabc)),
            chainId: block.chainid,
            questionHash: keccak256("q"),
            answerType: 5,
            answer: abi.encode(ranked),
            figure: 0,
            fromBlock: uint64(block.number - 100),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: bytes32(uint256(0xdef)),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        vm.prank(alice);
        vm.expectRevert(MarginaliaJudge.OnlyIntake.selector);
        judge.onOracleResult(reqId, att, hex"01");
        vm.prank(hook.INTAKE());
        judge.onOracleResult(reqId, att, hex"01");
        assertTrue(judge.judgedSet(day));
        uint256 pot = hook.potImd(day);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 aliceBefore = imd.balanceOf(alice);
        judge.payJudged(day);
        assertEq(imd.balanceOf(bob) - bobBefore, pot * 50 / 100);
        assertEq(imd.balanceOf(alice) - aliceBefore, pot * 30 / 100);
        assertEq(hook.potImd(day), 0);
        assertEq(hook.potImd(hook.today()), pot * 20 / 100); // the empty third slot rolls forward
        assertEq(hook.recordOf(bob).judgedWins, 1);
        vm.expectRevert(MarginaliaJudge.AlreadyPaid.selector);
        judge.payJudged(day);
    }

    function testForfeitsConvertToImdForThePot() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x"), 10 ether);
        vm.prank(alice);
        hook.retract(id, "out");
        uint256 marg = hook.potMarg();
        assertGt(marg, 0);
        uint256 potBefore = hook.potImd(hook.today());
        uint256 out = judge.convertForfeits();
        assertGt(out, 0);
        assertEq(hook.potMarg(), 0);
        assertEq(hook.potImd(hook.today()) - potBefore, out);
        assertEq(_claims(address(hook), address(token)), 0);
    }
}
