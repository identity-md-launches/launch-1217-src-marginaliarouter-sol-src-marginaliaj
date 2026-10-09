// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";

interface IMarginaliaHook {
    function getPoolKey() external view returns (PoolKey memory);
    function imd() external view returns (address);
    function token() external view returns (address);
}

interface IUniswapV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IUniswapV2PairSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice The only path that can attach a note to a MARG swap (plain buys and sells of MARG work through any
/// v4 router; the hook taxes sells wherever they come from). Funds are pulled only from msg.sender and
/// never held between transactions. Optionally trades X in the same transaction, on Uniswap v4, v3 or v2,
/// so the note's position is proven rather than claimed. The note must be about the token traded.
contract MarginaliaRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    IMarginaliaHook public immutable hook;

    uint8 public constant X_NONE = 0;
    uint8 public constant X_V4 = 1;
    uint8 public constant X_V3 = 2;
    uint8 public constant X_V2 = 3;

    /// @dev One X trade. v4 uses `key` + `zeroForOne`; v3 and v2 use `pool` + `tokenIn` (the pool decides the rest).
    struct XTrade {
        uint8 kind;
        PoolKey key;
        bool zeroForOne;
        address pool;
        address tokenIn;
        uint256 amountIn;
        uint256 minOut;
    }

    struct Job {
        address payer;
        bool sellMarg; // false: buy MARG with IMD and note; true: sell MARG for IMD and note (the 1% path)
        uint256 amountIn;
        uint256 minOut;
        XTrade x;
        uint256 xResult; // set before unlock for v3/v2 legs
        address xIn;
        address xOut;
        T.NoteParams note;
    }

    bytes32 private jobHash;
    address private v3Pending;

    error UnauthorizedCallback();
    error InvalidSwap();
    error Slippage();
    error Expired();
    error NoteTokenMismatch();

    event Noted(address indexed author, bool sellMarg, uint256 spent, uint256 received);
    event XTraded(address indexed trader, uint8 kind, address indexed xIn, address indexed xOut, uint256 spent, uint256 received);

    constructor(IPoolManager manager_, address hook_) {
        require(address(manager_).code.length > 0 && hook_ != address(0), "configuration required");
        manager = manager_;
        hook = IMarginaliaHook(hook_);
    }

    // ------------------------------------------------------------------ entry points

    /// @notice Post a note by buying MARG. Class is Declared unless the author is a contract (Agent).
    function note(T.NoteParams calldata p, uint256 imdIn, uint256 minMargOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        XTrade memory noX;
        return _run(false, imdIn, minMargOut, deadline, noX, p);
    }

    /// @notice Sell MARG with a note attached: 1% plus the stamp instead of the quiet 3%, and the deposit
    /// comes off the MARG sold. The note may be about any token (a SELL call on MARG itself is the natural one).
    function sellWithNote(T.NoteParams calldata p, uint256 margIn, uint256 minImdOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        XTrade memory noX;
        return _run(true, margIn, minImdOut, deadline, noX, p);
    }

    /// @notice Trade X (v4, v3 or v2) and post the note about it in one transaction (class Traded).
    function tradeAndNote(XTrade calldata x, T.NoteParams calldata p, uint256 imdIn, uint256 minMargOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        if (x.kind == X_NONE) revert InvalidSwap();
        return _run(false, imdIn, minMargOut, deadline, x, p);
    }

    // ------------------------------------------------------------------ core

    function _run(bool sellMarg, uint256 amountIn, uint256 minOut, uint256 deadline, XTrade memory x, T.NoteParams memory p)
        private
        returns (uint256 received)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidSwap();
        IERC20(sellMarg ? hook.token() : hook.imd()).safeTransferFrom(msg.sender, address(this), amountIn);

        Job memory job;
        job.payer = msg.sender;
        job.sellMarg = sellMarg;
        job.amountIn = amountIn;
        job.minOut = minOut;
        job.x = x;
        job.note = p;

        if (x.kind != X_NONE) {
            if (x.amountIn == 0) revert InvalidSwap();
            if (x.kind == X_V4) {
                address xIn = Currency.unwrap(x.zeroForOne ? x.key.currency0 : x.key.currency1);
                if (xIn == address(0)) revert InvalidSwap();
                IERC20(xIn).safeTransferFrom(msg.sender, address(this), x.amountIn);
                // traded inside the unlock
            } else {
                IERC20(x.tokenIn).safeTransferFrom(msg.sender, address(this), x.amountIn);
                (job.xResult, job.xIn, job.xOut) = x.kind == X_V3 ? _tradeV3(msg.sender, x) : _tradeV2(msg.sender, x);
                _checkSubject(job);
            }
        }

        bytes memory data = abi.encode(job);
        jobHash = keccak256(data);
        received = abi.decode(manager.unlock(data), (uint256));
        delete jobHash;
    }

    function _checkSubject(Job memory job) private pure {
        address subject = job.note.side == T.Side.Buy ? job.xOut : job.xIn;
        if (subject != job.note.x) revert NoteTokenMismatch();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || jobHash == bytes32(0) || keccak256(data) != jobHash) {
            revert UnauthorizedCallback();
        }
        delete jobHash;
        Job memory job = abi.decode(data, (Job));
        if (job.x.kind == X_V4) {
            (job.xResult, job.xIn, job.xOut) = _tradeV4(job.payer, job.x);
            _checkSubject(job);
        }

        PoolKey memory key = hook.getPoolKey();
        address imd = hook.imd();
        bool imd0 = Currency.unwrap(key.currency0) == imd;
        bool zeroForOne = job.sellMarg ? !imd0 : imd0; // IMD in / MARG out, or the reverse
        bytes memory hookData = abi.encode(T.DATA_NOTE, job.note, job.payer, job.xResult);

        BalanceDelta delta = manager.swap(
            key,
            SwapParams(zeroForOne, -int256(job.amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            hookData
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(uint128(-inputDelta));
        uint256 received = uint256(uint128(outputDelta));
        if (spent > job.amountIn || received < job.minOut) revert Slippage();
        Currency payCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency receiveCurrency = zeroForOne ? key.currency1 : key.currency0;
        _pay(payCurrency, spent);
        manager.take(receiveCurrency, job.payer, received);
        if (spent < job.amountIn) IERC20(Currency.unwrap(payCurrency)).safeTransfer(job.payer, job.amountIn - spent);
        emit Noted(job.payer, job.sellMarg, spent, received);
        return abi.encode(received);
    }

    // ------------------------------------------------------------------ X legs

    function _tradeV4(address payer, XTrade memory x) private returns (uint256 received, address xIn, address xOut) {
        BalanceDelta delta = manager.swap(
            x.key,
            SwapParams(x.zeroForOne, -int256(x.amountIn), x.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            ""
        );
        int128 inputDelta = x.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = x.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(uint128(-inputDelta));
        received = uint256(uint128(outputDelta));
        if (spent > x.amountIn || received < x.minOut) revert Slippage();
        Currency payCurrency = x.zeroForOne ? x.key.currency0 : x.key.currency1;
        Currency receiveCurrency = x.zeroForOne ? x.key.currency1 : x.key.currency0;
        _pay(payCurrency, spent);
        manager.take(receiveCurrency, payer, received);
        if (spent < x.amountIn) IERC20(Currency.unwrap(payCurrency)).safeTransfer(payer, x.amountIn - spent);
        xIn = Currency.unwrap(payCurrency);
        xOut = Currency.unwrap(receiveCurrency);
        emit XTraded(payer, X_V4, xIn, xOut, spent, received);
    }

    /// @dev Exact-input swap straight against a v3 pool; the pool pays the recipient, we pay in the callback.
    function _tradeV3(address payer, XTrade memory x) private returns (uint256 received, address xIn, address xOut) {
        IUniswapV3PoolSwap pool = IUniswapV3PoolSwap(x.pool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        bool zeroForOne = x.tokenIn == t0;
        if (!zeroForOne && x.tokenIn != t1) revert InvalidSwap();
        xIn = x.tokenIn;
        xOut = zeroForOne ? t1 : t0;
        uint256 before = IERC20(xOut).balanceOf(payer);
        v3Pending = x.pool;
        pool.swap(payer, zeroForOne, int256(x.amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, "");
        delete v3Pending;
        received = IERC20(xOut).balanceOf(payer) - before;
        if (received < x.minOut || received == 0) revert Slippage();
        uint256 left = IERC20(xIn).balanceOf(address(this));
        if (left > 0) IERC20(xIn).safeTransfer(payer, left);
        emit XTraded(payer, X_V3, xIn, xOut, x.amountIn - left, received);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != v3Pending || v3Pending == address(0)) revert UnauthorizedCallback();
        IUniswapV3PoolSwap pool = IUniswapV3PoolSwap(msg.sender);
        if (amount0Delta > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Exact-input swap against a v2 pair: send the input, take the constant-product output to the payer.
    function _tradeV2(address payer, XTrade memory x) private returns (uint256 received, address xIn, address xOut) {
        IUniswapV2PairSwap pair = IUniswapV2PairSwap(x.pool);
        address t0 = pair.token0();
        address t1 = pair.token1();
        bool zeroForOne = x.tokenIn == t0;
        if (!zeroForOne && x.tokenIn != t1) revert InvalidSwap();
        xIn = x.tokenIn;
        xOut = zeroForOne ? t1 : t0;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 pairBefore = IERC20(xIn).balanceOf(x.pool);
        IERC20(xIn).safeTransfer(x.pool, x.amountIn);
        uint256 actualIn = IERC20(xIn).balanceOf(x.pool) - pairBefore; // fee-on-transfer safe
        uint256 inWithFee = actualIn * 997;
        uint256 out = inWithFee * rOut / (rIn * 1000 + inWithFee);
        if (out == 0) revert Slippage();
        uint256 before = IERC20(xOut).balanceOf(payer);
        pair.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, payer, "");
        received = IERC20(xOut).balanceOf(payer) - before;
        if (received < x.minOut || received == 0) revert Slippage();
        emit XTraded(payer, X_V2, xIn, xOut, actualIn, received);
    }

    function _pay(Currency c, uint256 amount) private {
        manager.sync(c);
        IERC20(Currency.unwrap(c)).safeTransfer(address(manager), amount);
        if (manager.settle() != amount) revert InvalidSwap();
    }
}
