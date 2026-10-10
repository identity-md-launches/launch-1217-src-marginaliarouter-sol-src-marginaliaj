// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";

interface IHookJudge {
    function imd() external view returns (address);
    function thesisPool(uint32 week) external view returns (uint256);
    function potMarg() external view returns (uint256);
    function week() external view returns (uint32);
    function thesesOfWeek(uint32 week) external view returns (bytes32[] memory);
    function noteMeta(bytes32 id) external view returns (address author, uint32 week, bool thesis);
    function sellPotMarg(uint256 amount) external returns (uint256);
    function drawForJudging(uint32 day, uint256 amount) external;
    function payJudged(uint32 day, bytes32[3] calldata top) external;
    function JUDGE_PRICE() external view returns (uint256);
}

/// @notice The oracle consumer and a permissionless helper: once per week, converts forfeited MARG, draws
/// the oracle's price from the thesis pool, buys the panel's ranking of the week's long-form theses, verifies
/// the signed answer, and tells the hook whom to pay. Short-form calls are never judged: they resolve against
/// price and score the leaderboard. Deployed by the hook; no owner.
contract MarginaliaJudge is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant PANEL_SIZE = 7;
    uint16 public constant QUORUM = 5;
    /// @dev At most this many of a week's theses (the first posted) are put to the panel: the Intake refuses
    /// a body over 16 KiB, and 200 ids keep the body near 14 KiB whatever the chain id.
    uint256 public constant MAX_JUDGED = 200;
    /// @dev A request the Intake never answered (refused body, split panel, failed callback) can be made
    /// again this long after it was paid for. The attestation itself is asked to be valid for one day.
    uint64 public constant REQUEST_TTL = 3 days;
    /// @dev The live Intake price is paid as it is, up to this multiple (in basis points) of the price the
    /// hook was designed around, so a moved price does not stop judging and cannot drain the pool either.
    uint256 public constant PRICE_CAP_BPS = 20_000;

    IHookJudge public hook;
    IIntake public intake;
    bytes32 public action;

    mapping(uint32 => bytes32) public requestOf;
    mapping(uint32 => uint64) public requestedAt;
    mapping(bytes32 => uint32) private pendingDay; // day + 1, never zero
    mapping(uint32 => bytes32[3]) private judgedIds;
    mapping(uint32 => bool) public judgedSet;
    mapping(uint32 => bool) public paid;

    error DayNotOver();
    error AlreadyRequested();
    error AlreadyJudged();
    error NoNotes();
    error PriceMismatch();
    error OnlyIntake();
    error UnknownRequest();
    error BadAnswer();
    error NotJudged();
    error AlreadyPaid();
    error AlreadyInitialised();

    event Requested(uint32 indexed day, bytes32 indexed requestId, uint256 price);
    event RequestCleared(uint32 indexed day, bytes32 indexed requestId);
    event Judged(uint32 indexed day, bytes32[3] ids);

    /// @dev The implementation is an EIP-1167 target and never a judge itself: its constructor fills the init
    /// guard with its own address, so nobody can initialise the published implementation with a signer and
    /// hook of their choosing. The signer slot of the implementation is its own address for the same reason
    /// (the base refuses zero). A clone starts with empty storage, so its `init` still runs once.
    constructor() OracleAttestationConsumer(address(this)) {
        hook = IHookJudge(address(this));
    }

    /// @dev Called once by the hook on its clone, in the hook's constructor.
    function init(address hook_, address intake_, bytes32 action_, address signer_) external {
        if (address(hook) != address(0)) revert AlreadyInitialised();
        require(
            hook_ != address(0) && intake_ != address(0) && action_ != bytes32(0), "configuration required"
        );
        hook = IHookJudge(hook_);
        intake = IIntake(intake_);
        action = action_;
        _setOracleSigner(signer_);
    }

    /// @notice Converts any forfeited MARG into IMD for today's pot. Anyone, any time.
    function convertForfeits() external nonReentrant returns (uint256 imdOut) {
        uint256 marg = hook.potMarg();
        if (marg == 0) return 0;
        imdOut = hook.sellPotMarg(marg);
    }

    /// @notice The oracle body for a week: deterministic from the week's thesis ids, so anyone can check it.
    /// At most `MAX_JUDGED` ids, in posting order.
    function questionBody(uint32 week) public view returns (string memory) {
        return string(
            bytes.concat(
                bytes(
                    '{"v":1,"question":"Rank the three best-argued Marginalia theses among these ids by verifiable reasoning and citations (on-chain reads, named addresses, holder or liquidity facts, mechanism arguments, sourced claims). A thesis without reasoning scores zero. Ignore whether its calls proved right.","chainId":'
                ),
                _dec(block.chainid),
                bytes(
                    ',"window":{"hours":168},"answerType":"bytes32[]","evidence":"panel","head":3,"panelSize":'
                ),
                _dec(PANEL_SIZE),
                bytes(',"quorum":'),
                _dec(QUORUM),
                bytes(',"validForSeconds":86400,"guards":{"allow":['),
                _allowList(hook.thesesOfWeek(week)),
                bytes(']},"consumer":{"chainId":'),
                _dec(block.chainid),
                bytes(',"verifyingContract":"'),
                _hex(uint256(uint160(address(this))), 20),
                bytes('"}}')
            )
        );
    }

    /// @dev `"0x…",` per id, written once into a buffer of the exact size (linear, not a concat per id).
    function _allowList(bytes32[] memory ids) private pure returns (bytes memory out) {
        uint256 n = ids.length > MAX_JUDGED ? MAX_JUDGED : ids.length;
        if (n == 0) return out;
        out = new bytes(n * 68 + (n - 1)); // "0x" + 64 hex digits + two quotes, a comma between entries
        uint256 pos;
        for (uint256 i = 0; i < n; ++i) {
            if (i > 0) out[pos++] = ",";
            out[pos++] = '"';
            _hexInto(out, pos, uint256(ids[i]), 32);
            pos += 66;
            out[pos++] = '"';
        }
    }

    function _hexInto(bytes memory out, uint256 pos, uint256 v, uint256 len) private pure {
        bytes16 digits = "0123456789abcdef";
        out[pos] = "0";
        out[pos + 1] = "x";
        for (uint256 i = pos + 2 + len * 2; i > pos + 2; --i) {
            out[i - 1] = digits[v & 0xf];
            v >>= 4;
        }
    }

    function _hex(uint256 v, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(2 + len * 2);
        _hexInto(out, 0, v, len);
    }

    function _dec(uint256 v) private pure returns (bytes memory) {
        if (v == 0) return "0";
        uint256 n;
        for (uint256 t = v; t > 0; t /= 10) {
            ++n;
        }
        bytes memory out = new bytes(n);
        for (uint256 i = n; i > 0; --i) {
            out[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return out;
    }

    /// @notice Buys the panel's ranking for a finished week whose thesis pool clears the hook's threshold.
    /// A week whose request got no answer within `REQUEST_TTL` may be requested again; the old request is
    /// forgotten, so a late answer to it is refused.
    function requestJudging(uint32 day) external nonReentrant returns (bytes32 requestId) {
        if (day >= hook.week()) revert DayNotOver();
        if (judgedSet[day]) revert AlreadyJudged();
        bytes32 prior = requestOf[day];
        if (prior != bytes32(0)) {
            if (block.timestamp < uint256(requestedAt[day]) + REQUEST_TTL) revert AlreadyRequested();
            delete pendingDay[prior];
            emit RequestCleared(day, prior);
        }
        if (hook.thesesOfWeek(day).length == 0) revert NoNotes();
        address imd = hook.imd();
        uint256 price = intake.priceOf(action, imd);
        if (price == 0 || price > hook.JUDGE_PRICE() * PRICE_CAP_BPS / 10_000) revert PriceMismatch();
        hook.drawForJudging(day, price);
        IERC20(imd).forceApprove(address(intake), price);
        bytes memory body = bytes(questionBody(day));
        requestId = intake.request(
            action, body, IIntake.Callback(address(this), this.onOracleResult.selector), imd, price
        );
        IERC20(imd).forceApprove(address(intake), 0);
        if (pendingDay[requestId] != 0) revert AlreadyRequested();
        requestOf[day] = requestId;
        requestedAt[day] = uint64(block.timestamp);
        pendingDay[requestId] = day + 1;
        emit Requested(day, requestId, price);
    }

    /// @notice The Intake delivers the panel's ranking here. Verified, filtered to the week's theses, stored.
    /// A ranking that names none of the week's theses is stored as a judged week with no winners, so
    /// `payJudged` rolls the pool forward rather than the week staying open for ever.
    function onOracleResult(
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external nonReentrant {
        if (msg.sender != address(intake)) revert OnlyIntake();
        uint32 stored = pendingDay[requestId];
        if (stored == 0) revert UnknownRequest();
        delete pendingDay[requestId];
        uint32 day = stored - 1;
        _verifyAttestation(a, signature);
        if (a.agreed < a.quorum || a.quorum < QUORUM || a.panelSize < PANEL_SIZE || judgedSet[day]) {
            revert BadAnswer();
        }
        bytes32[] memory ranked = decodeBytes32List(a);
        _consume(a.requestId);
        bytes32[3] memory top;
        uint256 kept;
        for (uint256 i = 0; i < ranked.length && kept < 3; ++i) {
            (address author, uint32 noteWeek, bool thesis) = hook.noteMeta(ranked[i]);
            if (author == address(0) || noteWeek != day || !thesis) continue;
            bool dup;
            for (uint256 k = 0; k < kept; ++k) {
                if (top[k] == ranked[i]) dup = true;
            }
            if (dup) continue;
            top[kept++] = ranked[i];
        }
        judgedIds[day] = top;
        judgedSet[day] = true;
        emit Judged(day, top);
    }

    function judgedOf(uint32 day) external view returns (bytes32[3] memory) {
        return judgedIds[day];
    }

    /// @notice Pays a judged week. Anyone may call it once the ranking is in.
    function payJudged(uint32 day) external nonReentrant {
        if (!judgedSet[day]) revert NotJudged();
        if (paid[day]) revert AlreadyPaid();
        paid[day] = true;
        hook.payJudged(day, judgedIds[day]);
    }
}
