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

/// @notice The only path that can attach a note to a MARG swap. Funds are pulled only from msg.sender,
/// never held between transactions. Optionally executes a trade of X on a Uniswap v4 pool in the same
/// transaction, so the note's position is proven rather than claimed.
contract MarginaliaRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    IMarginaliaHook public immutable hook;

    struct XTrade {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    struct Job {
        address payer;
        uint8 kind; // 0 plain buy, 1 noted buy, 2 quiet sell, 3 noted sell (X = MARG)
        uint256 amountIn;
        uint256 minOut;
        bool hasX;
        XTrade x;
        T.NoteParams note;
    }

    bytes32 private jobHash;

    error UnauthorizedCallback();
    error InvalidSwap();
    error Slippage();
    error Expired();

    event Swapped(address indexed trader, bool buy, uint256 spent, uint256 received, bool noted);
    event XTraded(address indexed trader, address indexed xIn, address indexed xOut, uint256 spent, uint256 received);

    constructor(IPoolManager manager_, address hook_) {
        require(address(manager_).code.length > 0 && hook_ != address(0), "configuration required");
        manager = manager_;
        hook = IMarginaliaHook(hook_);
    }

    /// @notice Buy MARG with IMD (exact input). With a note, the stamp and deposit come off the swap.
    function buy(uint256 imdIn, uint256 minMargOut, uint256 deadline) external nonReentrant returns (uint256 received) {
        T.NoteParams memory none;
        return _run(0, imdIn, minMargOut, deadline, false, _emptyX(), none);
    }

    /// @notice Post a note by buying MARG. Class is Declared unless the author is a contract (Agent).
    function note(T.NoteParams calldata p, uint256 imdIn, uint256 minMargOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received)
    {
        return _run(1, imdIn, minMargOut, deadline, false, _emptyX(), p);
    }

    /// @notice Trade X on a v4 pool and post the note about it in one transaction (class Traded).
    function tradeAndNote(
        XTrade calldata x,
        T.NoteParams calldata p,
        uint256 imdIn,
        uint256 minMargOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        return _run(1, imdIn, minMargOut, deadline, true, x, p);
    }

    /// @notice Sell MARG for IMD (exact input). Quiet sells pay the 3% fee.
    function sell(uint256 margIn, uint256 minImdOut, uint256 deadline) external nonReentrant returns (uint256 received) {
        T.NoteParams memory none;
        return _run(2, margIn, minImdOut, deadline, false, _emptyX(), none);
    }

    /// @notice Sell MARG with a SELL note on MARG itself: 1% fee plus the stamp, and a deposit off the input.
    function sellWithNote(T.NoteParams calldata p, uint256 margIn, uint256 minImdOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received)
    {
        return _run(3, margIn, minImdOut, deadline, false, _emptyX(), p);
    }

    function _emptyX() private pure returns (XTrade memory x) {}

    function _run(
        uint8 kind,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bool hasX,
        XTrade memory x,
        T.NoteParams memory p
    ) private returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidSwap();
        bool isBuy = kind == 0 || kind == 1;
        address input = isBuy ? hook.imd() : hook.token();
        IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        if (hasX) {
            address xIn = Currency.unwrap(x.zeroForOne ? x.key.currency0 : x.key.currency1);
            if (xIn == address(0) || x.amountIn == 0) revert InvalidSwap();
            IERC20(xIn).safeTransferFrom(msg.sender, address(this), x.amountIn);
        }
        Job memory job = Job(msg.sender, kind, amountIn, minOut, hasX, x, p);
        bytes memory data = abi.encode(job);
        jobHash = keccak256(data);
        received = abi.decode(manager.unlock(data), (uint256));
        delete jobHash;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || jobHash == bytes32(0) || keccak256(data) != jobHash) {
            revert UnauthorizedCallback();
        }
        delete jobHash;
        Job memory job = abi.decode(data, (Job));
        uint256 xResult;
        if (job.hasX) xResult = _tradeX(job.payer, job.x);

        PoolKey memory key = hook.getPoolKey();
        address imd = hook.imd();
        bool imd0 = Currency.unwrap(key.currency0) == imd;
        bool isBuy = job.kind == 0 || job.kind == 1;
        bool zeroForOne = isBuy == imd0;
        bytes memory hookData;
        if (job.kind == 1) hookData = abi.encode(T.DATA_NOTE, job.note, job.payer, xResult);
        else if (job.kind == 3) hookData = abi.encode(T.DATA_SELL_NOTE, job.note, job.payer, uint256(0));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                zeroForOne, -int256(job.amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
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
        emit Swapped(job.payer, isBuy, spent, received, job.kind == 1 || job.kind == 3);
        return abi.encode(received);
    }

    function _tradeX(address payer, XTrade memory x) private returns (uint256 received) {
        BalanceDelta delta = manager.swap(
            x.key,
            SwapParams(
                x.zeroForOne,
                -int256(x.amountIn),
                x.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
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
        emit XTraded(payer, Currency.unwrap(payCurrency), Currency.unwrap(receiveCurrency), spent, received);
    }

    function _pay(Currency c, uint256 amount) private {
        manager.sync(c);
        IERC20(Currency.unwrap(c)).safeTransfer(address(manager), amount);
        if (manager.settle() != amount) revert InvalidSwap();
    }
}
