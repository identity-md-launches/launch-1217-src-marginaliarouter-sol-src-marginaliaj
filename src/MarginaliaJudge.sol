// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";

interface IHookJudge {
    function imd() external view returns (address);
    function potImd(uint32 day) external view returns (uint256);
    function potMarg() external view returns (uint256);
    function today() external view returns (uint32);
    function notesOfDay(uint32 day) external view returns (bytes32[] memory);
    function noteMeta(bytes32 id) external view returns (address author, uint32 day);
    function sellPotMarg(uint256 amount) external returns (uint256);
    function drawForJudging(uint32 day, uint256 amount) external;
    function payJudged(uint32 day, bytes32[3] calldata top) external;
    function JUDGE_PRICE() external view returns (uint256);
}

/// @notice The oracle consumer and a permissionless helper: once per UTC day, converts forfeited MARG,
/// draws the oracle's price from the pot, buys the panel's ranking of the day's notes, verifies the signed
/// answer, and tells the hook whom to pay. Deployed by the hook; no owner.
contract MarginaliaJudge is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant PANEL_SIZE = 7;
    uint16 public constant QUORUM = 5;

    IHookJudge public immutable hook;
    IIntake public immutable intake;
    bytes32 public immutable action;

    mapping(uint32 => bytes32) public requestOf;
    mapping(bytes32 => uint32) private pendingDay; // day + 1, never zero
    mapping(uint32 => bytes32[3]) private judgedIds;
    mapping(uint32 => bool) public judgedSet;
    mapping(uint32 => bool) public paid;

    error DayNotOver();
    error AlreadyRequested();
    error NoNotes();
    error PriceMismatch();
    error OnlyIntake();
    error UnknownRequest();
    error BadAnswer();
    error NotJudged();
    error AlreadyPaid();

    event Requested(uint32 indexed day, bytes32 indexed requestId, uint256 price);
    event Judged(uint32 indexed day, bytes32[3] ids);

    constructor(address hook_, address intake_, bytes32 action_, address signer_) OracleAttestationConsumer(signer_) {
        require(hook_ != address(0) && intake_ != address(0) && action_ != bytes32(0), "configuration required");
        hook = IHookJudge(hook_);
        intake = IIntake(intake_);
        action = action_;
    }

    /// @notice Converts any forfeited MARG into IMD for today's pot. Anyone, any time.
    function convertForfeits() external nonReentrant returns (uint256 imdOut) {
        uint256 marg = hook.potMarg();
        if (marg == 0) return 0;
        imdOut = hook.sellPotMarg(marg);
    }

    /// @notice The oracle body for a day: deterministic from the day's note ids, so anyone can check it.
    function questionBody(uint32 day) public view returns (string memory) {
        bytes32[] memory ids = hook.notesOfDay(day);
        bytes memory allow;
        for (uint256 i = 0; i < ids.length; ++i) {
            allow = bytes.concat(allow, i == 0 ? bytes('"') : bytes(',"'), _hex(uint256(ids[i]), 32), bytes('"'));
        }
        return string(
            bytes.concat(
                bytes('{"v":1,"question":"Rank the three best-argued Marginalia notes among these ids by verifiable reasoning (on-chain reads, named addresses, holder or liquidity facts, mechanism arguments). Direction-only notes score zero. Ignore whether the call proved right.","chainId":'),
                _dec(block.chainid),
                bytes(',"window":{"hours":24},"answerType":"bytes32[]","evidence":"panel","head":3,"panelSize":'),
                _dec(PANEL_SIZE),
                bytes(',"quorum":'),
                _dec(QUORUM),
                bytes(',"validForSeconds":86400,"guards":{"allow":['),
                allow,
                bytes(']},"consumer":{"chainId":'),
                _dec(block.chainid),
                bytes(',"verifyingContract":"'),
                _hex(uint256(uint160(address(this))), 20),
                bytes('"}}')
            )
        );
    }

    function _hex(uint256 v, uint256 len) private pure returns (bytes memory out) {
        bytes16 digits = "0123456789abcdef";
        out = new bytes(2 + len * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 2 + len * 2; i > 2; --i) {
            out[i - 1] = digits[v & 0xf];
            v >>= 4;
        }
    }

    function _dec(uint256 v) private pure returns (bytes memory) {
        if (v == 0) return "0";
        uint256 n;
        for (uint256 t = v; t > 0; t /= 10) ++n;
        bytes memory out = new bytes(n);
        for (uint256 i = n; i > 0; --i) {
            out[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return out;
    }

    /// @notice Buys the panel's ranking for a finished day whose pot clears the hook's threshold.
    function requestJudging(uint32 day) external nonReentrant returns (bytes32 requestId) {
        if (day >= hook.today()) revert DayNotOver();
        if (requestOf[day] != bytes32(0)) revert AlreadyRequested();
        if (hook.notesOfDay(day).length == 0) revert NoNotes();
        address imd = hook.imd();
        uint256 price = intake.priceOf(action, imd);
        if (price == 0 || price != hook.JUDGE_PRICE()) revert PriceMismatch();
        hook.drawForJudging(day, price);
        IERC20(imd).forceApprove(address(intake), price);
        bytes memory body = bytes(questionBody(day));
        requestId = intake.request(action, body, IIntake.Callback(address(this), this.onOracleResult.selector), imd, price);
        IERC20(imd).forceApprove(address(intake), 0);
        if (pendingDay[requestId] != 0) revert AlreadyRequested();
        requestOf[day] = requestId;
        pendingDay[requestId] = day + 1;
        emit Requested(day, requestId, price);
    }

    /// @notice The Intake delivers the panel's ranking here. Verified, filtered to the day's notes, stored.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (msg.sender != address(intake)) revert OnlyIntake();
        uint32 stored = pendingDay[requestId];
        if (stored == 0) revert UnknownRequest();
        delete pendingDay[requestId];
        uint32 day = stored - 1;
        _verifyAttestation(a, signature);
        if (a.agreed < a.quorum || a.quorum < QUORUM || judgedSet[day]) revert BadAnswer();
        bytes32[] memory ranked = decodeBytes32List(a);
        _consume(a.requestId);
        bytes32[3] memory top;
        uint256 kept;
        for (uint256 i = 0; i < ranked.length && kept < 3; ++i) {
            (address author, uint32 noteDay) = hook.noteMeta(ranked[i]);
            if (author == address(0) || noteDay != day) continue;
            bool dup;
            for (uint256 k = 0; k < kept; ++k) {
                if (top[k] == ranked[i]) dup = true;
            }
            if (dup) continue;
            top[kept++] = ranked[i];
        }
        if (kept == 0) revert BadAnswer();
        judgedIds[day] = top;
        judgedSet[day] = true;
        emit Judged(day, top);
    }

    function judgedOf(uint32 day) external view returns (bytes32[3] memory) {
        return judgedIds[day];
    }

    /// @notice Pays a judged day. Anyone may call it once the ranking is in.
    function payJudged(uint32 day) external nonReentrant {
        if (!judgedSet[day]) revert NotJudged();
        if (paid[day]) revert AlreadyPaid();
        paid[day] = true;
        hook.payJudged(day, judgedIds[day]);
    }
}
