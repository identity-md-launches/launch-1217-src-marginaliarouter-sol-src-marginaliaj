// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Marginalia} from "../../src/Marginalia.sol";
import {MarginaliaHook} from "../../src/MarginaliaHook.sol";
import {MarginaliaRouter} from "../../src/MarginaliaRouter.sol";
import {MarginaliaTreasury} from "../../src/MarginaliaTreasury.sol";
import {MarginaliaJudge} from "../../src/MarginaliaJudge.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MarginaliaTypes as T} from "../../src/MarginaliaTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

contract LiquidityHelper is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, int256 amount) external {
        manager.unlock(abi.encode(key, ModifyLiquidityParams(lower, upper, amount, bytes32(0))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, ModifyLiquidityParams memory p) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, p, "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 d) private {
        if (d < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(manager), uint256(-int256(d)));
            require(manager.settle() == uint256(-int256(d)));
        } else if (d > 0) {
            manager.take(c, address(this), uint256(uint128(d)));
        }
    }
}

/// @dev Any v4 router can buy or sell MARG; this is the test's plain one (no notes).
contract TestSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) external returns (uint256 received) {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountIn, payer)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = manager.swap(
            key,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            ""
        );
        int128 inD = zeroForOne ? d.amount0() : d.amount1();
        int128 outD = zeroForOne ? d.amount1() : d.amount0();
        require(inD < 0 && outD > 0, "bad swap");
        Currency pay = zeroForOne ? key.currency0 : key.currency1;
        Currency recv = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(pay);
        IERC20(Currency.unwrap(pay)).safeTransferFrom(payer, address(manager), uint256(-int256(inD)));
        manager.settle();
        manager.take(recv, payer, uint256(uint128(outD)));
        return abi.encode(uint256(uint128(outD)));
    }
}

/// @dev Stands in for the IMD Intake at its mainnet address (etched by the fixture).
contract MockIntake is IIntake {
    uint256 public constant price = 0.5 ether;
    uint256 public requests;
    bytes public lastBody;
    address public lastTarget;
    bytes4 public lastSelector;

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        lastBody = body;
        lastTarget = callback.target;
        lastSelector = callback.selector;
        requestId = keccak256(abi.encode(requests, body));
    }
}

/// @dev Stands in for the oracle signer: an ERC-1271 account that accepts everything.
contract MockSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

abstract contract Fixture is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    Marginalia internal token;
    MockERC20 internal imd;
    MarginaliaHook internal hook;
    MarginaliaRouter internal router;
    MarginaliaTreasury internal treasury;
    MarginaliaJudge internal judge;
    PoolKey internal key;
    PoolId internal poolId;
    LiquidityHelper internal liquidity;
    TestSwapRouter internal plain;
    bool internal margIs0;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _deployHook(IPoolManager m, address t) internal returns (MarginaliaHook result) {
        bytes memory code = abi.encodePacked(type(MarginaliaHook).creationCode, abi.encode(m, t, address(this)));
        bytes32 hash = keccak256(code);
        for (uint256 i = 0; i < 300_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, HookFlags.MARGINALIA)) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(code, 32), mload(code), salt)
            }
            require(deployed == predicted && deployed.code.length > 0, "deployment failed");
            return MarginaliaHook(deployed);
        }
        revert("mining exhausted");
    }

    /// @dev Two-sided pool at 1 MARG = 1 IMD, wide range, so prices can move far in tests.
    function _setup() internal {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new Marginalia();
        imd = new MockERC20("Identity.md", "IMD", 1_000_000_000 ether);
        hook = _deployHook(manager, address(token));
        router = hook.router();
        treasury = hook.treasury();
        judge = hook.judge();
        margIs0 = address(token) < address(imd);
        (address c0, address c1) = margIs0 ? (address(token), address(imd)) : (address(imd), address(token));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, uint160(1 << 96));
        liquidity = new LiquidityHelper(manager);
        plain = new TestSwapRouter(manager);
        token.transfer(address(liquidity), 50_000_000 ether);
        imd.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(key, -6000, 6000, 10_000_000 ether);
        imd.transfer(alice, 1_000_000 ether);
        imd.transfer(bob, 5_000_000 ether);
        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 100_000 ether);
        vm.startPrank(alice);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(plain), type(uint256).max);
        token.approve(address(plain), type(uint256).max);
        imd.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(plain), type(uint256).max);
        token.approve(address(plain), type(uint256).max);
        vm.stopPrank();
        // The oracle stand-ins live at the hook's hardcoded mainnet addresses.
        vm.etch(hook.INTAKE(), address(new MockIntake()).code);
        vm.etch(hook.ORACLE_SIGNER(), address(new MockSigner()).code);
    }

    function _margNote(T.Side side, uint32 targetBps, uint16 horizonDays, string memory text)
        internal
        view
        returns (T.NoteParams memory p)
    {
        p.x = address(token);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(poolId), address(imd), margIs0);
        p.side = side;
        p.targetBps = targetBps;
        p.horizonDays = horizonDays;
        p.class = uint8(T.Class.Declared);
        p.text = text;
    }

    function _note(address who, T.NoteParams memory p, uint256 imdIn) internal returns (bytes32 id, uint256 received) {
        vm.prank(who);
        received = router.note(p, imdIn, 1, block.timestamp + 1);
        id = bytes32(hook.noteCount());
    }

    function _buy(address who, uint256 imdIn) internal returns (uint256 received) {
        received = plain.swap(key, !margIs0, imdIn, who); // IMD in
    }

    function _sell(address who, uint256 margIn) internal returns (uint256 received) {
        received = plain.swap(key, margIs0, margIn, who); // MARG in
    }

    function _claims(address holder, address currency) internal view returns (uint256) {
        return manager.balanceOf(holder, uint256(uint160(currency)));
    }
}
