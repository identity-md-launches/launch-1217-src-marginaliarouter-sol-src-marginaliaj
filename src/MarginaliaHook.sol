// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";
import {PriceAdapters} from "./PriceAdapters.sol";
import {MarginaliaTreasury} from "./MarginaliaTreasury.sol";
import {MarginaliaRouter} from "./MarginaliaRouter.sol";
import {MarginaliaJudge} from "./MarginaliaJudge.sol";

/// @title Marginalia: notes in the margin of every trade
/// @notice A Uniswap v4 hook on the MARG/IMD launch pool. Buying MARG through the router with a note in
/// hookData posts a falsifiable call on any ERC-20: a flat stamp (0.1 IMD-equivalent, to the pot) and a
/// flat deposit (0.5 IMD-equivalent of the bought MARG, locked for the horizon). The call resolves against
/// the median of on-chain price observations; a right, still-held call gets its deposit back; anything
/// else forfeits it to the pot. The pot pays the best-argued notes of the day, ranked by the IMD oracle
/// panel, which this contract verifies as the attestation's consumer. No owner, no pause, no upgrade.
contract MarginaliaHook is IUnlockCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants

    uint256 public constant STAMP = 0.1 ether; // IMD-equivalent, non-refundable, to the pot
    uint256 public constant DEPOSIT = 0.5 ether; // IMD-equivalent of MARG, refundable
    uint256 public constant SELL_NOTED_BPS = 100;
    uint256 public constant SELL_QUIET_BPS = 300;
    uint32 public constant MIN_TARGET_DELTA_BPS = 1000;
    uint16 public constant MAX_HORIZON_DAYS = 90;
    uint256 public constant TEXT_MAX = 280;
    uint256 public constant THESIS_TEXT_MAX = 8192;
    uint256 public constant THESIS_GRACE = 7 days;
    uint256 public constant SETTLE_WINDOW = 6 hours;
    uint256 public constant OBS_MIN = 3;
    uint256 public constant OBS_MAX = 16;
    uint256 public constant OBS_GAP_BLOCKS = 20;
    uint256 public constant KEEPER_BPS = 200;
    uint256 public constant MAX_DAY_NOTES = 256;
    uint256 public constant JUDGE_THRESHOLD = 2 ether; // IMD
    uint256 public constant JUDGE_PRICE = 0.5 ether; // IMD, the Intake's oracle.request price
    uint256 public constant LP_FEE = 12_500;

    /// @dev IMD-denominated market-cap tiers for the difficulty score (~$1M / ~$10M at IMD ≈ $9).
    uint256 public constant TIER2_MCAP_IMD = 111_000 ether;
    uint256 public constant TIER3_MCAP_IMD = 1_110_000 ether;

    /// @dev The IMD oracle (Ethereum mainnet and Robinhood Chain share these addresses).
    address public constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    /// @dev Ethereum mainnet ETH/IMD hub pool (1% fee, tick spacing 200, no hook): native is token0.
    bytes32 public constant HUB_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ------------------------------------------------------------------ immutables and pool state

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    MarginaliaTreasury public immutable treasury;
    MarginaliaRouter public immutable router;
    MarginaliaJudge public immutable judge;

    address public imd;
    bool public initialized;
    bool private imdIs0;
    PoolKey private pool;
    PoolId public poolId;

    // ------------------------------------------------------------------ notes

    uint256 public noteCount;
    mapping(bytes32 => T.Note) private notes;
    mapping(bytes32 => T.Observation[]) private observations;
    mapping(uint32 => bytes32[]) private dayNotes;

    struct Record {
        int256 score;
        uint32 posted;
        uint32 right;
        uint32 wrong;
        uint32 broken;
        uint32 retracted;
        uint32 judgedWins;
    }

    mapping(address => Record) public records;

    // ------------------------------------------------------------------ pot and judging

    /// @dev IMD held as ERC-6909 claims, by UTC day of accrual.
    mapping(uint32 => uint256) public potImd;
    /// @dev Forfeited MARG held as claims, converted to IMD by the judge before judging.
    uint256 public potMarg;
    mapping(uint32 => bool) public judgedPaid;

    // ------------------------------------------------------------------ transient-ish scratch

    uint256 private pendingSellDeposit;
    bytes32 private unlockHash;

    uint8 private constant ACT_PAY = 1; // burn claims, take currency to `to`
    uint8 private constant ACT_FUND = 2; // move ERC-20 IMD into claims
    uint8 private constant ACT_SELL = 3; // swap MARG claims to IMD (to `to`, or kept as claims)

    // ------------------------------------------------------------------ errors and events

    error Unauthorized();
    error InvalidPool();
    error PartialFill();
    error BadHookData();
    error NoteNeedsExactInput();
    error NoteTooSmall();
    error InvalidNote();
    error UnknownNote();
    error NotOpen();
    error TooEarly();
    error TooLate();
    error ObservationTooSoon();
    error NothingToClaim();
    error AlreadyPaid();
    error InvalidUnlock();
    error PotTooSmall();
    error QuoteNotPriceable();

    event PoolBound(PoolId indexed poolId, address indexed imd);
    event SwapFee(bool indexed buy, address indexed trader, uint256 poolImd, uint256 fee, uint256 stamp);
    event NotePosted(
        bytes32 indexed id,
        address indexed author,
        address indexed x,
        uint8 class,
        T.Side side,
        uint32 targetBps,
        uint16 horizonDays,
        uint256 postPrice,
        uint256 deposit,
        bytes32 parentId,
        uint256 xResult,
        string text
    );
    event Observed(bytes32 indexed id, uint64 blockNumber, uint256 price, uint256 balance);
    event Settled(bytes32 indexed id, T.Status status, uint256 settlePrice, int256 scoreDelta, address keeper);
    event Retracted(bytes32 indexed id, string text);
    event DepositClaimed(bytes32 indexed id, address indexed to, bool asImd, uint256 amount);
    event ThesisReleased(bytes32 indexed id);
    event ThesisForfeited(bytes32 indexed id);
    event PotFunded(uint32 indexed day, uint256 amount, address indexed source);
    event PotMargSold(uint256 marg, uint256 imdOut, uint32 indexed day);
    event JudgedPaid(uint32 indexed day, uint256[3] amounts);

    // ------------------------------------------------------------------ construction

    constructor(IPoolManager poolManager_, address token_, address factory_) {
        require(
            address(poolManager_).code.length > 0 && token_.code.length > 0 && factory_ != address(0),
            "configuration required"
        );
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        treasury = new MarginaliaTreasury(address(this));
        router = new MarginaliaRouter(poolManager_, address(this));
        judge = new MarginaliaJudge(address(this), INTAKE, ACTION, ORACLE_SIGNER);
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ------------------------------------------------------------------ pool binding

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        if (sender != factory || initialized || key.fee != LP_FEE || address(key.hooks) != address(this)) {
            revert InvalidPool();
        }
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = a == token ? b : (b == token ? a : address(0));
        if (pair == address(0) || pair.code.length == 0) revert InvalidPool();
        imd = pair;
        imdIs0 = (a == pair);
        pool = key;
        poolId = key.toId();
        initialized = true;
        emit PoolBound(poolId, pair);
        return IHooks.beforeInitialize.selector;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        if (!initialized) revert InvalidPool();
        return pool;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    // ------------------------------------------------------------------ swaps

    function _dataKind(address sender, bytes calldata data) private view returns (uint8 kind) {
        if (data.length == 0) return 0;
        kind = abi.decode(data, (uint8));
        if (kind == T.DATA_EXEMPT) {
            if (sender != address(this)) revert BadHookData();
        } else if (kind == T.DATA_NOTE || kind == T.DATA_SELL_NOTE) {
            if (sender != address(router)) revert BadHookData();
        } else {
            revert BadHookData();
        }
    }

    /// @dev Current MARG price in IMD from the bound pool, 1e18 scaled.
    function margPriceInImd() public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        return PriceAdapters.fromSqrt(sqrtP, !imdIs0);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        uint8 kind = _dataKind(sender, data);
        uint256 specifiedTake = 0;
        if (buy) {
            if (kind == T.DATA_NOTE) {
                // The stamp comes off the specified IMD input; the deposit comes off the MARG output in afterSwap.
                if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
                if (uint256(-params.amountSpecified) <= STAMP * 2) revert NoteTooSmall();
                specifiedTake = STAMP;
            }
        } else if (kind == T.DATA_SELL_NOTE) {
            // A noted sell on MARG itself: the deposit is MARG taken off the specified input.
            if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
            uint256 depositMarg = FullMath.mulDiv(DEPOSIT, 1e18, margPriceInImd());
            if (uint256(-params.amountSpecified) <= depositMarg * 2) revert NoteTooSmall();
            pendingSellDeposit = depositMarg;
            specifiedTake = depositMarg;
        } else if (kind != T.DATA_EXEMPT && params.amountSpecified > 0) {
            // Exact-output IMD sell: gross the quiet fee up so the requested output is net of it.
            uint256 bps = SELL_QUIET_BPS;
            specifiedTake = (uint256(params.amountSpecified) * bps + (10_000 - bps) - 1) / (10_000 - bps);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedTake.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
        int128 margDelta = imdIs0 ? delta.amount1() : delta.amount0();
        if ((buy && imdDelta >= 0) || (!buy && imdDelta <= 0)) revert PartialFill();
        uint256 poolImd = buy ? uint256(uint128(-imdDelta)) : uint256(uint128(imdDelta));
        uint8 kind = _dataKind(sender, data);
        uint32 day = _today();

        if (buy) {
            if (kind != T.DATA_NOTE) return (IHooks.afterSwap.selector, 0);
            uint256 netIn = uint256(-params.amountSpecified) - STAMP;
            if (poolImd != netIn) revert PartialFill();
            uint256 margOut = uint256(uint128(margDelta));
            uint256 depositMarg = FullMath.mulDiv(DEPOSIT, margOut, netIn);
            if (margOut <= depositMarg + 1) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), STAMP);
            poolManager.mint(address(this), _id(token), depositMarg);
            potImd[day] += STAMP;
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            _postNote(author, p, xResult, depositMarg);
            emit SwapFee(true, author, poolImd, 0, STAMP);
            return (IHooks.afterSwap.selector, depositMarg.toInt128());
        }

        if (kind == T.DATA_EXEMPT) return (IHooks.afterSwap.selector, 0);

        if (kind == T.DATA_SELL_NOTE) {
            uint256 depositMarg = pendingSellDeposit;
            delete pendingSellDeposit;
            uint256 fee = poolImd * SELL_NOTED_BPS / 10_000 + STAMP;
            if (poolImd <= fee) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), fee);
            poolManager.mint(address(this), _id(token), depositMarg);
            potImd[day] += fee;
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            if (p.x != token) revert InvalidNote();
            _postNote(author, p, xResult, depositMarg);
            emit SwapFee(false, author, poolImd, fee - STAMP, STAMP);
            return (IHooks.afterSwap.selector, fee.toInt128());
        }

        // Quiet sell.
        uint256 quietFee;
        int128 returned = 0;
        if (params.amountSpecified > 0) {
            uint256 bps = SELL_QUIET_BPS;
            quietFee = (uint256(params.amountSpecified) * bps + (10_000 - bps) - 1) / (10_000 - bps);
            if (poolImd != uint256(params.amountSpecified) + quietFee) revert PartialFill();
        } else {
            quietFee = poolImd * SELL_QUIET_BPS / 10_000;
            returned = quietFee.toInt128();
        }
        if (quietFee > 0) {
            poolManager.mint(address(this), _id(imd), quietFee);
            potImd[day] += quietFee;
        }
        emit SwapFee(false, tx.origin, poolImd, quietFee, 0);
        return (IHooks.afterSwap.selector, returned);
    }

    function _decodeNote(bytes calldata data) private pure returns (T.NoteParams memory p, address author, uint256 xResult) {
        (, p, author, xResult) = abi.decode(data, (uint8, T.NoteParams, address, uint256));
        if (author == address(0)) revert BadHookData();
    }

    // ------------------------------------------------------------------ notes

    function _postNote(address author, T.NoteParams memory p, uint256 xResult, uint256 depositMarg) private {
        bool thesis = p.targetBps == 0;
        uint256 textLen = bytes(p.text).length;
        if (thesis) {
            if (textLen == 0 || textLen > THESIS_TEXT_MAX || p.parentId != bytes32(0)) revert InvalidNote();
        } else {
            if (textLen == 0 || textLen > TEXT_MAX) revert InvalidNote();
            if (p.horizonDays == 0 || p.horizonDays > MAX_HORIZON_DAYS) revert InvalidNote();
            if (p.side == T.Side.Buy) {
                if (p.targetBps < 10_000 + MIN_TARGET_DELTA_BPS) revert InvalidNote();
            } else {
                if (p.targetBps >= 10_000 || p.targetBps + MIN_TARGET_DELTA_BPS > 10_000) revert InvalidNote();
            }
            if (p.x == address(0) || p.x.code.length == 0) revert InvalidNote();
        }
        uint8 class = p.class;
        if (class > uint8(T.Class.Attested)) revert InvalidNote();
        if (xResult > 0) class = uint8(T.Class.Traded);
        else if (class == uint8(T.Class.Traded)) class = uint8(T.Class.Declared);
        if (author.code.length > 0) class = uint8(T.Class.Agent);

        bytes32 id = bytes32(++noteCount);
        T.Note storage n = notes[id];
        n.author = author;
        n.x = p.x;
        n.venue = p.venue;
        n.side = p.side;
        n.targetBps = p.targetBps;
        n.horizonDays = p.horizonDays;
        n.class = class;
        n.postedAt = uint64(block.timestamp);
        n.day = _today();
        n.deposit = depositMarg;
        n.parentId = p.parentId;
        n.textHash = keccak256(bytes(p.text));
        if (thesis) {
            n.status = T.Status.ThesisOpen;
        } else {
            n.postPrice = _priceInImd(p.venue);
            n.postBalance = IERC20(p.x).balanceOf(author);
            if (p.parentId != bytes32(0)) {
                T.Note storage parent = notes[p.parentId];
                if (parent.author != author || parent.status != T.Status.ThesisOpen) revert InvalidNote();
                parent.children += 1;
            }
            if (dayNotes[n.day].length < MAX_DAY_NOTES) dayNotes[n.day].push(id);
        }
        records[author].posted += 1;
        emit NotePosted(
            id, author, p.x, class, p.side, p.targetBps, p.horizonDays, n.postPrice, depositMarg, p.parentId, xResult, p.text
        );
    }

    /// @dev X priced in IMD, 1e18 scaled: the venue's quote price times the quote's IMD price.
    function _priceInImd(T.Venue memory v) private view returns (uint256) {
        uint256 inQuote = PriceAdapters.priceInQuote(poolManager, v);
        if (v.quote == imd) return inQuote;
        if (v.quote == address(0) || v.quote == WETH) {
            if (block.chainid != 1) revert QuoteNotPriceable();
            (uint160 sqrtP,,,) = poolManager.getSlot0(PoolId.wrap(HUB_POOL_ID));
            uint256 ethInImd = PriceAdapters.fromSqrt(sqrtP, true);
            return FullMath.mulDiv(inQuote, ethInImd, 1e18);
        }
        revert QuoteNotPriceable();
    }

    function horizonEnd(bytes32 id) public view returns (uint256) {
        T.Note storage n = _note(id);
        return uint256(n.postedAt) + uint256(n.horizonDays) * 1 days;
    }

    /// @notice Anyone records a price and balance observation inside the settlement window.
    function observe(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp < end) revert TooEarly();
        if (block.timestamp > end + SETTLE_WINDOW) revert TooLate();
        T.Observation[] storage obs = observations[id];
        if (obs.length >= OBS_MAX) revert TooLate();
        if (obs.length > 0 && block.number < obs[obs.length - 1].blockNumber + OBS_GAP_BLOCKS) {
            revert ObservationTooSoon();
        }
        uint256 price = _priceInImd(n.venue);
        uint256 balance = IERC20(n.x).balanceOf(n.author);
        obs.push(T.Observation(uint64(block.number), uint192(price), balance));
        emit Observed(id, uint64(block.number), price, balance);
    }

    /// @notice Anyone settles a note once its window has closed. The keeper earns 2% of a forfeited deposit.
    function settle(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp <= end + SETTLE_WINDOW) revert TooEarly();
        T.Observation[] storage obs = observations[id];
        uint256 count = obs.length;
        T.Status outcome;
        uint256 settlePrice;
        if (count < OBS_MIN) {
            outcome = T.Status.VoidNoData;
        } else {
            bool held = true;
            uint256[] memory prices = new uint256[](count);
            for (uint256 i = 0; i < count; ++i) {
                prices[i] = obs[i].price;
                if (n.side == T.Side.Buy ? obs[i].balance < n.postBalance : obs[i].balance > n.postBalance) {
                    held = false;
                }
            }
            settlePrice = _median(prices);
            if (!held) {
                outcome = T.Status.VoidSold;
            } else if (n.side == T.Side.Buy) {
                outcome = settlePrice * 10_000 >= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            } else {
                outcome = settlePrice * 10_000 <= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            }
        }
        n.status = outcome;
        int256 scoreDelta = 0;
        Record storage r = records[n.author];
        if (outcome == T.Status.Right) {
            scoreDelta = int256(_difficulty(n));
            r.right += 1;
        } else if (outcome == T.Status.Wrong) {
            scoreDelta = -int256(_difficulty(n));
            r.wrong += 1;
            _forfeit(n, msg.sender);
        } else if (outcome == T.Status.VoidSold) {
            scoreDelta = -int256(_difficulty(n));
            r.broken += 1;
            _forfeit(n, msg.sender);
        }
        r.score += scoreDelta;
        _resolveChild(n);
        emit Settled(id, outcome, settlePrice, scoreDelta, msg.sender);
    }

    /// @notice The author withdraws a call before its horizon: the deposit goes to the pot, the reason is public.
    function retract(bytes32 id, string calldata text) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.status != T.Status.Open) revert NotOpen();
        if (block.timestamp >= horizonEnd(id)) revert TooLate();
        n.status = T.Status.Retracted;
        int256 scoreDelta = -int256(_difficulty(n) / 2);
        Record storage r = records[n.author];
        r.retracted += 1;
        r.score += scoreDelta;
        _forfeit(n, address(0));
        _resolveChild(n);
        emit Retracted(id, text);
        emit Settled(id, T.Status.Retracted, 0, scoreDelta, address(0));
    }

    /// @notice A thesis with no child call inside the grace period forfeits its deposit.
    function settleThesis(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.ThesisOpen) revert NotOpen();
        if (n.children > 0) revert NotOpen();
        if (block.timestamp <= uint256(n.postedAt) + THESIS_GRACE) revert TooEarly();
        n.status = T.Status.ThesisForfeited;
        _forfeit(n, msg.sender);
        emit ThesisForfeited(id);
    }

    /// @notice A right (or no-data, or released thesis) deposit, returned as MARG, or swapped to IMD fee-free.
    function claimDeposit(bytes32 id, bool asImd) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (
            n.status != T.Status.Right && n.status != T.Status.VoidNoData && n.status != T.Status.ThesisClosed
        ) revert NothingToClaim();
        uint256 amount = n.deposit;
        if (amount == 0) revert NothingToClaim();
        n.deposit = 0;
        if (asImd) {
            _unlock(ACT_SELL, n.author, amount, 0);
        } else {
            _unlock(ACT_PAY, n.author, amount, uint256(uint160(token)));
        }
        emit DepositClaimed(id, n.author, asImd, amount);
    }

    function _forfeit(T.Note storage n, address keeper) private {
        uint256 amount = n.deposit;
        n.deposit = 0;
        if (amount == 0) return;
        uint256 reward = keeper == address(0) ? 0 : amount * KEEPER_BPS / 10_000;
        if (reward > 0) _unlock(ACT_PAY, keeper, reward, uint256(uint160(token)));
        potMarg += amount - reward;
    }

    function _resolveChild(T.Note storage n) private {
        if (n.parentId == bytes32(0)) return;
        T.Note storage parent = notes[n.parentId];
        parent.resolvedChildren += 1;
        if (parent.status == T.Status.ThesisOpen) {
            parent.status = T.Status.ThesisClosed;
            emit ThesisReleased(n.parentId);
        }
    }

    // ------------------------------------------------------------------ score

    /// @dev log2(claimed multiple) × sqrt(30 / horizon) × mcap tier, scaled 1e4.
    function _difficulty(T.Note storage n) private view returns (uint256) {
        uint256 ratio = n.side == T.Side.Buy ? n.targetBps : FullMath.mulDiv(10_000, 10_000, n.targetBps);
        uint256 l2 = _log2x1e4(ratio); // 1e4 scaled bits
        uint256 s = _sqrt(FullMath.mulDiv(30, 1e8, n.horizonDays)); // sqrt(30/h) × 1e4
        uint256 mcap = FullMath.mulDiv(n.postPrice, IERC20(n.x).totalSupply(), 1e18);
        uint256 tier = mcap >= TIER3_MCAP_IMD ? 3 : (mcap >= TIER2_MCAP_IMD ? 2 : 1);
        return FullMath.mulDiv(l2, s, 1e4) * tier;
    }

    /// @dev log2 of a ratio given ×1e4 (ratio ≥ 1e4), returned ×1e4 with 1/16 precision.
    function _log2x1e4(uint256 r) private pure returns (uint256 result) {
        uint256 n;
        while (r >= 20_000) {
            r /= 2;
            n += 1;
        }
        result = n * 1e4;
        uint256 frac = 5000;
        for (uint256 i = 0; i < 4; ++i) {
            r = r * r / 1e4;
            if (r >= 20_000) {
                result += frac;
                r /= 2;
            }
            frac /= 2;
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _median(uint256[] memory a) private pure returns (uint256) {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; ++i) {
            uint256 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = v;
        }
        return n % 2 == 1 ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2;
    }

    // ------------------------------------------------------------------ pot and judging

    function _today() private view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function notesOfDay(uint32 day) external view returns (bytes32[] memory) {
        return dayNotes[day];
    }

    /// @notice Moves ERC-20 IMD from the caller into today's pot (the treasury's drip, or anyone's gift).
    function fundPot(uint256 amount) external {
        if (amount == 0) revert PotTooSmall();
        IERC20(imd).safeTransferFrom(msg.sender, address(this), amount);
        _unlock(ACT_FUND, address(0), amount, 0);
        uint32 day = _today();
        potImd[day] += amount;
        emit PotFunded(day, amount, msg.sender);
    }

    /// @notice Converts forfeited MARG into IMD for today's pot. Judge-only so the timing is predictable.
    function sellPotMarg(uint256 amount) external returns (uint256 imdOut) {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (amount == 0 || amount > potMarg) revert PotTooSmall();
        potMarg -= amount;
        imdOut = _unlock(ACT_SELL, address(0), amount, 0);
        uint32 day = _today();
        potImd[day] += imdOut;
        emit PotMargSold(amount, imdOut, day);
    }

    /// @notice The judge draws the oracle's price out of a day's pot.
    function drawForJudging(uint32 day, uint256 amount) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (potImd[day] < JUDGE_THRESHOLD || amount > potImd[day]) revert PotTooSmall();
        potImd[day] -= amount;
        _unlock(ACT_PAY, address(judge), amount, uint256(uint160(imd)));
    }

    /// @notice Who wrote a note and on which day: what the judge needs to filter the panel's ranking.
    function noteMeta(bytes32 id) external view returns (address author, uint32 day) {
        T.Note storage n = notes[id];
        return (n.author, n.day);
    }

    /// @notice Pays a judged day's pot 50/30/20 to the ranked authors. The judge supplies the verified ranking.
    function payJudged(uint32 day, bytes32[3] calldata top) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (judgedPaid[day]) revert AlreadyPaid();
        judgedPaid[day] = true;
        uint256 pot = potImd[day];
        potImd[day] = 0;
        uint256[3] memory shares = [pot * 50 / 100, pot * 30 / 100, pot * 20 / 100];
        uint256[3] memory paidAmounts;
        uint256 leftover = pot;
        for (uint256 i = 0; i < 3; ++i) {
            if (top[i] == bytes32(0)) continue;
            address to = notes[top[i]].author;
            records[to].judgedWins += 1;
            _unlock(ACT_PAY, to, shares[i], uint256(uint160(imd)));
            paidAmounts[i] = shares[i];
            leftover -= shares[i];
        }
        if (leftover > 0) potImd[_today()] += leftover; // unranked slots roll forward
        emit JudgedPaid(day, paidAmounts);
    }

    // ------------------------------------------------------------------ unlock plumbing

    function _id(address c) private pure returns (uint256) {
        return uint256(uint160(c));
    }

    function _unlock(uint8 action, address to, uint256 amount, uint256 extra) private returns (uint256 result) {
        bytes memory data = abi.encode(action, to, amount, extra);
        unlockHash = keccak256(data);
        bytes memory out = poolManager.unlock(data);
        if (unlockHash != bytes32(0)) revert InvalidUnlock();
        if (out.length == 32) result = abi.decode(out, (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (unlockHash == bytes32(0) || keccak256(data) != unlockHash) revert InvalidUnlock();
        delete unlockHash;
        (uint8 action, address to, uint256 amount, uint256 extra) = abi.decode(data, (uint8, address, uint256, uint256));
        if (action == ACT_PAY) {
            address currency = address(uint160(extra));
            poolManager.burn(address(this), _id(currency), amount);
            poolManager.take(Currency.wrap(currency), to, amount);
            return "";
        }
        if (action == ACT_FUND) {
            Currency c = Currency.wrap(imd);
            poolManager.sync(c);
            IERC20(imd).safeTransfer(address(poolManager), amount);
            poolManager.settle();
            poolManager.mint(address(this), _id(imd), amount);
            return "";
        }
        if (action == ACT_SELL) {
            bool zeroForOne = !imdIs0; // MARG → IMD
            BalanceDelta delta = poolManager.swap(
                pool,
                SwapParams(
                    zeroForOne,
                    -int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                abi.encode(T.DATA_EXEMPT)
            );
            int128 margDelta = imdIs0 ? delta.amount1() : delta.amount0();
            int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
            if (margDelta >= 0 || imdDelta <= 0) revert InvalidUnlock();
            poolManager.burn(address(this), _id(token), uint256(uint128(-margDelta)));
            uint256 imdOut = uint256(uint128(imdDelta));
            if (to == address(0)) {
                poolManager.mint(address(this), _id(imd), imdOut);
            } else {
                poolManager.take(Currency.wrap(imd), to, imdOut);
            }
            return abi.encode(imdOut);
        }
        revert InvalidUnlock();
    }

    // ------------------------------------------------------------------ views

    function _note(bytes32 id) private view returns (T.Note storage n) {
        n = notes[id];
        if (n.author == address(0)) revert UnknownNote();
    }

    function noteOf(bytes32 id) external view returns (T.Note memory) {
        return _note(id);
    }

    function observationsOf(bytes32 id) external view returns (T.Observation[] memory) {
        return observations[id];
    }

    function recordOf(address wallet) external view returns (Record memory) {
        return records[wallet];
    }
}
