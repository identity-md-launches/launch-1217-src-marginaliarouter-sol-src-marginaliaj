// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaTreasury} from "../src/MarginaliaTreasury.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev An Intake stand-in whose price moves and that never calls back on its own (the live Intake's
/// behaviour for a refused body or a split panel).
contract PricedIntake is IIntake {
    uint256 public price;
    uint256 public requests;
    bytes32 public lastBodyHash;
    uint256 public lastBodyLength;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        lastBodyHash = keccak256(body); // the live Intake does not store the body; a mock that did would dominate gas
        lastBodyLength = body.length;
        requestId = keccak256(abi.encode(requests, body));
    }
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function register(address t0, address t1, uint24 fee, address pool) external {
        getPool[t0][t1][fee] = pool;
    }
}

/// @dev A v3-shaped pool: pays 1:1, and asks the caller for `takeBps` of the specified input (a partial fill).
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint256 public takeBps;

    constructor(address a, address b, uint24 fee_, uint256 takeBps_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = fee_;
        takeBps = takeBps_;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        uint256 inAmt = uint256(amountSpecified) * takeBps / 10_000;
        address tokenIn = zeroForOne ? token0 : token1;
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, inAmt);
        a0 = zeroForOne ? int256(inAmt) : -int256(inAmt);
        a1 = zeroForOne ? -int256(inAmt) : int256(inAmt);
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IV3Callback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + inAmt, "unpaid");
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function register(address a, address b, address pair) external {
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (
            uint112(IERC20(token0).balanceOf(address(this))),
            uint112(IERC20(token1).balanceOf(address(this))),
            0
        );
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
    }
}

/// @notice The audit findings on the three companions (and the hook's thesis-pool sweep), reproduced and fixed.
contract CompanionsTest is Fixture {
    PricedIntake intake;
    MockERC20 x;
    MockV3Factory v3Factory;
    MockV2Factory v2Factory;

    function setUp() public {
        _setup();
        vm.etch(hook.INTAKE(), address(new PricedIntake()).code);
        intake = PricedIntake(hook.INTAKE());
        intake.setPrice(0.5 ether);
        imd.transfer(carol, 100_000 ether);
        vm.startPrank(carol);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        x = new MockERC20("X", "X", 1_000_000 ether);
        vm.etch(router.V3_FACTORY(), address(new MockV3Factory()).code);
        vm.etch(router.V2_FACTORY(), address(new MockV2Factory()).code);
        v3Factory = MockV3Factory(router.V3_FACTORY());
        v2Factory = MockV2Factory(router.V2_FACTORY());
    }

    // ------------------------------------------------------------------ helpers

    function _thesis(address who) internal returns (bytes32 id) {
        (id,) = _note(who, _margNote(T.Side.Buy, 0, 0, "thesis: argued and cited"), 10 ether);
    }

    /// @dev `n` theses by rotating authors, a funded pot, and the week over.
    function _thesisWeek(uint256 n) internal returns (uint32 w, bytes32[] memory ids) {
        w = hook.week();
        ids = new bytes32[](n);
        address[3] memory authors = [alice, bob, carol];
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

    function _xThesis() internal view returns (T.NoteParams memory p) {
        p.x = address(x);
        p.side = T.Side.Buy;
        p.class = uint8(T.Class.Declared);
        p.text = "thesis about X";
    }

    // ------------------------------------------------------------------ implementations are locked

    function testImplementationsCannotBeInitialised() public {
        MarginaliaRouter r = new MarginaliaRouter();
        MarginaliaJudge j = new MarginaliaJudge();
        MarginaliaTreasury t = new MarginaliaTreasury();
        assertEq(address(r.hook()), address(r));
        assertEq(address(j.hook()), address(j));
        assertEq(address(t.hook()), address(t));
        (address intake_, bytes32 action_, address signer_) =
            (hook.INTAKE(), hook.ACTION(), hook.ORACLE_SIGNER());
        vm.expectRevert(MarginaliaRouter.AlreadyInitialised.selector);
        r.init(manager, address(hook));
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        j.init(address(hook), intake_, action_, signer_);
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        t.init(address(hook));
        // IMD sent to a locked implementation cannot be dripped anywhere: hook.imd() is the treasury itself
        imd.transfer(address(t), 100 ether);
        vm.expectRevert();
        t.drip();
    }

    function testClonesInitialiseOnce() public {
        vm.expectRevert(MarginaliaRouter.AlreadyInitialised.selector);
        router.init(manager, alice);
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        judge.init(alice, alice, bytes32("x"), alice);
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        treasury.init(alice);
        assertEq(address(treasury.hook()), address(hook));
        assertEq(address(router.hook()), address(hook));
        assertEq(address(judge.hook()), address(hook));
        assertEq(judge.oracleSigner(), hook.ORACLE_SIGNER());
    }

    // ------------------------------------------------------------------ treasury

    function testTreasuryRejectsEth() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok, "clone accepted ETH it can never move");
        MarginaliaTreasury impl = new MarginaliaTreasury();
        vm.prank(alice);
        (ok,) = address(impl).call{value: 1 ether}("");
        assertFalse(ok, "implementation accepted ETH it can never move");
        assertEq(address(treasury).balance, 0);
        // IMD still drips
        imd.transfer(address(treasury), 1000 ether);
        treasury.drip();
        assertEq(hook.thesisPool(hook.week()), 6 ether);
    }

    // ------------------------------------------------------------------ judge: answers

    function testJudgeRefusesASmallerPanel() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(2);
        bytes32 reqId = judge.requestJudging(w);
        vm.prank(address(intake));
        vm.expectRevert(MarginaliaJudge.BadAnswer.selector);
        judge.onOracleResult(reqId, _att(ids, 5), hex"01");
        // the same answer from the asked-for panel is fine
        _deliver(reqId, ids, 7);
        assertTrue(judge.judgedSet(w));
        assertEq(judge.judgedOf(w)[0], ids[0]);
    }

    function testNoWinnersIsStoredAndRollsThePoolForward() public {
        (uint32 w,) = _thesisWeek(1);
        (bytes32 call1,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "a short call"), 10 ether);
        bytes32 reqId = judge.requestJudging(w);
        uint256 pool = hook.thesisPool(w);
        assertGt(pool, 0);
        bytes32[] memory ranked = new bytes32[](2);
        ranked[0] = call1; // not a thesis
        ranked[1] = keccak256("not a note");
        _deliver(reqId, ranked, 7); // stored, not reverted
        assertTrue(judge.judgedSet(w));
        assertEq(judge.judgedOf(w)[0], bytes32(0));
        vm.expectRevert(MarginaliaJudge.AlreadyJudged.selector);
        judge.requestJudging(w);
        uint256 current = hook.thesisPool(hook.week());
        judge.payJudged(w);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()), current + pool);
    }

    function testCallbackFitsTheIntakeStipend() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(3);
        bytes32 reqId = judge.requestJudging(w);
        vm.prank(address(intake));
        judge.onOracleResult{gas: 200_000}(reqId, _att(ids, 7), hex"01");
        assertTrue(judge.judgedSet(w));
        bytes32[3] memory top = judge.judgedOf(w);
        assertEq(top[0], ids[0]);
        assertEq(top[1], ids[1]);
        assertEq(top[2], ids[2]);
        judge.payJudged(w);
        assertTrue(hook.judgedPaid(w));
    }

    // ------------------------------------------------------------------ judge: requests

    function testUnansweredRequestCanBeMadeAgain() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(1);
        uint256 poolBefore = hook.thesisPool(w);
        bytes32 first = judge.requestJudging(w);
        assertEq(hook.thesisPool(w), poolBefore - 0.5 ether);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(w);
        vm.warp(block.timestamp + judge.REQUEST_TTL() - 1);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(w);
        vm.warp(block.timestamp + 1);
        bytes32 second = judge.requestJudging(w);
        assertTrue(second != first);
        assertEq(intake.requests(), 2);
        assertEq(judge.requestOf(w), second);
        // a late answer to the forgotten request is refused; the live one judges the week
        vm.prank(address(intake));
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.onOracleResult(first, _att(ids, 7), hex"01");
        _deliver(second, ids, 7);
        assertTrue(judge.judgedSet(w));
        uint256 pool = hook.thesisPool(w);
        uint256 before = imd.balanceOf(alice);
        judge.payJudged(w);
        assertEq(imd.balanceOf(alice) - before, pool / 2);
    }

    function testJudgePaysTheLivePriceUpToACap() public {
        (uint32 w,) = _thesisWeek(1);
        uint256 cap = hook.JUDGE_PRICE() * judge.PRICE_CAP_BPS() / 10_000;
        intake.setPrice(cap + 1);
        vm.expectRevert(MarginaliaJudge.PriceMismatch.selector);
        judge.requestJudging(w);
        intake.setPrice(0);
        vm.expectRevert(MarginaliaJudge.PriceMismatch.selector);
        judge.requestJudging(w);
        intake.setPrice(0.6 ether);
        uint256 pool = hook.thesisPool(w);
        judge.requestJudging(w);
        assertEq(hook.thesisPool(w), pool - 0.6 ether);
        assertEq(imd.balanceOf(address(intake)), 0.6 ether);
        // a lower price next week is paid as it is
        (uint32 w2,) = _thesisWeek(1);
        intake.setPrice(0.4 ether);
        pool = hook.thesisPool(w2);
        judge.requestJudging(w2);
        assertEq(hook.thesisPool(w2), pool - 0.4 ether);
    }

    function testBodyStaysUnderTheIntakeLimitWithAFullWeek() public {
        uint32 w = hook.week();
        for (uint256 i = 0; i < hook.MAX_DAY_NOTES(); ++i) {
            _thesis(alice);
        }
        assertEq(hook.thesesOfWeek(w).length, 256);
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp(block.timestamp + 7 days);
        uint256 gasBefore = gasleft();
        judge.requestJudging(w);
        uint256 used = gasBefore - gasleft();
        bytes memory body = bytes(judge.questionBody(w));
        assertEq(keccak256(body), intake.lastBodyHash());
        assertLe(body.length, 16_384, "body over the Intake's limit");
        assertLt(used, 8_000_000, "request too expensive"); // 30M+ before the linear body build; ~5M now
        // the first MAX_JUDGED ids are listed, in posting order, and the last one is not
        bytes memory firstId = bytes(vm.toString(bytes32(uint256(1))));
        bytes memory lastId = bytes(vm.toString(bytes32(uint256(256))));
        assertTrue(_contains(body, firstId));
        assertFalse(_contains(body, lastId));
        assertTrue(_contains(body, bytes(vm.toString(bytes32(judge.MAX_JUDGED())))));
        assertFalse(_contains(body, bytes(vm.toString(bytes32(judge.MAX_JUDGED() + 1)))));
    }

    function testQuestionBodyShape() public {
        (uint32 w, bytes32[] memory ids) = _thesisWeek(2);
        bytes memory body = bytes(judge.questionBody(w));
        bytes memory expected = bytes(
            string.concat(
                '"guards":{"allow":["',
                vm.toString(ids[0]),
                '","',
                vm.toString(ids[1]),
                '"]},"consumer":{"chainId":',
                vm.toString(block.chainid),
                ',"verifyingContract":"',
                vm.toLowercase(vm.toString(address(judge))),
                '"}}'
            )
        );
        assertTrue(_contains(body, expected), string(body));
        assertTrue(_contains(body, bytes('"panelSize":7,"quorum":5,"validForSeconds":86400')));
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

    // ------------------------------------------------------------------ hook: thesis pool of a quiet week

    function testQuietWeekThesisPoolRollsForward() public {
        uint32 w = hook.week();
        imd.transfer(address(treasury), 10_000 ether);
        treasury.drip(); // 200 IMD accrued, no thesis this week
        assertEq(hook.thesisPool(w), 60 ether);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(MarginaliaJudge.NoNotes.selector);
        judge.requestJudging(w);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.sweep(2, w);
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER());
        hook.sweep(2, w);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()), 60 ether);
        vm.expectRevert(MarginaliaHook.NothingToSweep.selector);
        hook.sweep(2, w);
    }

    // ------------------------------------------------------------------ router: venues

    function testFakeV3PoolCannotProveATrade() public {
        MockV3Pool fake = new MockV3Pool(address(imd), address(x), 3000, 10_000);
        x.transfer(address(fake), 1000 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.UnknownVenue.selector);
        router.tradeAndNote(
            _xTrade(2, address(fake), address(imd), 1 ether), _xThesis(), 10 ether, 1, block.timestamp
        );
        assertEq(hook.noteCount(), 0);
    }

    function testFakeV2PairCannotProveATrade() public {
        MockV2Pair fake = new MockV2Pair(address(imd), address(x));
        x.transfer(address(fake), 1000 ether);
        imd.transfer(address(fake), 1000 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.UnknownVenue.selector);
        router.tradeAndNote(
            _xTrade(3, address(fake), address(imd), 1 ether), _xThesis(), 10 ether, 1, block.timestamp
        );
        assertEq(hook.noteCount(), 0);
    }

    function testCanonicalV2PairProvesATrade() public {
        MockV2Pair pair = new MockV2Pair(address(imd), address(x));
        x.transfer(address(pair), 1000 ether);
        imd.transfer(address(pair), 1000 ether);
        v2Factory.register(address(imd), address(x), address(pair));
        uint256 xBefore = x.balanceOf(alice);
        vm.prank(alice);
        router.tradeAndNote(
            _xTrade(3, address(pair), address(imd), 1 ether), _xThesis(), 10 ether, 1, block.timestamp
        );
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertEq(n.x, address(x));
        assertGt(x.balanceOf(alice), xBefore);
    }

    /// @dev The v3 leg selling IMD (the note's own input token) used to refund the note's IMD and underflow.
    function testV3LegSellingImdRefundsOnlyTheUnspentPart() public {
        MockV3Pool pool = new MockV3Pool(address(imd), address(x), 3000, 8_000); // fills 80% of the input
        x.transfer(address(pool), 1000 ether);
        v3Factory.register(pool.token0(), pool.token1(), 3000, address(pool));
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 xBefore = x.balanceOf(alice);
        vm.prank(alice);
        router.tradeAndNote(
            _xTrade(2, address(pool), address(imd), 5 ether), _xThesis(), 10 ether, 1, block.timestamp
        );
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertEq(x.balanceOf(alice) - xBefore, 4 ether);
        // 4 IMD on the leg plus the 10 IMD note: the unfilled 1 IMD came back, nothing stays in the router
        assertEq(imdBefore - imd.balanceOf(alice), 14 ether);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(x.balanceOf(address(router)), 0);
    }

    function testV3LegBuyingImdWorks() public {
        MockV3Pool pool = new MockV3Pool(address(imd), address(x), 500, 10_000);
        imd.transfer(address(pool), 1000 ether);
        v3Factory.register(pool.token0(), pool.token1(), 500, address(pool));
        x.transfer(alice, 10 ether);
        vm.prank(alice);
        x.approve(address(router), type(uint256).max);
        T.NoteParams memory p = _xThesis();
        p.side = T.Side.Sell; // a SELL thesis about X: the token sold must be X
        vm.prank(alice);
        router.tradeAndNote(_xTrade(2, address(pool), address(x), 3 ether), p, 10 ether, 1, block.timestamp);
        assertEq(x.balanceOf(alice), 7 ether);
        assertEq(uint8(hook.noteOf(bytes32(hook.noteCount())).class), uint8(T.Class.Traded));
        assertEq(imd.balanceOf(address(router)), 0);
    }
}
