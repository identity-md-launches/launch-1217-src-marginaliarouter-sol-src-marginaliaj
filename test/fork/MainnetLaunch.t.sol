// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Marginalia} from "../../src/Marginalia.sol";
import {MarginaliaHook} from "../../src/MarginaliaHook.sol";
import {MarginaliaRouter} from "../../src/MarginaliaRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MarginaliaTypes as T} from "../../src/MarginaliaTypes.sol";
import {ILaunchFactory} from "../../src/interfaces/ILaunchFactory.sol";

/// @notice The rehearsal: the real IMD LaunchFactory on a mainnet fork, impersonating its launch wallet,
/// deploys Marginalia exactly as a protocol launch would, then a user posts a note through the router.
/// Run: MAINNET_RPC_URL=... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
contract MainnetLaunchTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ILaunchFactory constant FACTORY = ILaunchFactory(0x12C63b581d07093F6126bc02263c58f7EadaA96F);
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint64 constant LAUNCH_NUMBER = 999_001;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint16 constant POOL_BPS = 9000;
    /// @dev The policy's opening cap for IMD pairing: 2,500 IMD across 1e9 MARG.
    uint256 constant OPENING_CAP_IMD = 2500 ether;

    address requester = makeAddr("requester");
    address alice = makeAddr("alice");
    Marginalia token;
    MarginaliaHook hook;
    MarginaliaRouter router;
    PoolKey key;
    uint256 launchGas;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _mine(bytes memory hookCode) internal view returns (bytes32 salt) {
        bytes32 hash = keccak256(hookCode);
        for (uint256 i = 1; i < 500_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(FACTORY), bytes32(i), hash))))
            );
            if (HookFlags.matches(predicted, HookFlags.MARGINALIA)) return bytes32(i);
        }
        revert("mining exhausted");
    }

    function _launch() internal {
        bytes memory tokenCode = type(Marginalia).creationCode;
        address predictedToken = FACTORY.predictToken(LAUNCH_NUMBER, tokenCode);
        bytes memory hookCode =
            abi.encodePacked(type(MarginaliaHook).creationCode, abi.encode(PM, predictedToken, address(FACTORY)));
        bytes32 salt = _mine(hookCode);

        bool margIs0 = predictedToken < IMD;
        // price (token1 per token0) at the opening cap: 2.5e-6 IMD per MARG
        uint256 priceX18 = margIs0 ? OPENING_CAP_IMD * 1e18 / SUPPLY : SUPPLY * 1e18 / OPENING_CAP_IMD;
        uint160 sqrtPriceX96 = uint160(_sqrt(priceX18 * (1 << 96) / 1e18 * (1 << 96)));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 spacing = 60;
        int24 tickLower;
        int24 tickUpper;
        uint128 liq;
        uint256 amount = SUPPLY * POOL_BPS / 10_000 * 999 / 1000;
        if (margIs0) {
            tickLower = ((tick / spacing) + 1) * spacing;
            tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
            uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sb = TickMath.getSqrtPriceAtTick(tickUpper);
            uint256 inter = FullMath.mulDiv(sa, sb, 1 << 96);
            liq = uint128(FullMath.mulDiv(amount, inter, sb - sa));
        } else {
            tickLower = (TickMath.MIN_TICK / spacing) * spacing;
            tickUpper = ((tick / spacing) - 1) * spacing;
            uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sb = TickMath.getSqrtPriceAtTick(tickUpper);
            liq = uint128(FullMath.mulDiv(amount, 1 << 96, sb - sa));
        }

        uint256[] memory agentIds;
        ILaunchFactory.LaunchParams memory params = ILaunchFactory.LaunchParams({
            launchNumber: LAUNCH_NUMBER,
            kind: bytes32("univ4_hook"),
            tokenCreationCode: tokenCode,
            hookCreationCode: hookCode,
            hookSalt: salt,
            hookFlags: HookFlags.MARGINALIA,
            totalSupply: SUPPLY,
            poolBps: POOL_BPS,
            remainderTo: requester,
            merkleRoot: keccak256("rehearsal"),
            contributorLockSeconds: 3600,
            sweepDelaySeconds: 1 days,
            pairedCurrency: Currency.wrap(IMD),
            fee: 12500,
            tickSpacing: spacing,
            sqrtPriceX96: sqrtPriceX96,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liq,
            record: ILaunchFactory.Launch({
                kind: bytes32("univ4_hook"),
                launchNumber: LAUNCH_NUMBER,
                recordedAt: 0,
                sourceCommit: bytes32(0),
                manifestHash: bytes32(0),
                attestationHash: bytes32(0),
                verifierKey: bytes32(0),
                sourceRepoUrl: "https://github.com/rehearsal/marginalia"
            }),
            agentIds: agentIds,
            requester: requester
        });

        address deployer = FACTORY.deployer();
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        uint256 g = gasleft();
        (address t, address h,) = FACTORY.launch(params);
        launchGas = g - gasleft();
        token = Marginalia(t);
        hook = MarginaliaHook(h);
        router = hook.router();
        key = hook.getPoolKey();
        assertEq(t, predictedToken, "token address");
    }

    function testLaunchThroughTheRealFactory() public {
        _launch();
        emit log_named_uint("launch gas", launchGas);
        assertTrue(hook.initialized());
        assertEq(hook.imd(), IMD);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(address(key.hooks), address(hook));
        assertEq(key.fee, 12500);
        // remainder landed with the requester; the pool took (almost) everything else
        assertGt(token.balanceOf(requester), 0);
        assertLt(token.balanceOf(requester), SUPPLY / 10);
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        assertGt(sqrtP, 0);
        emit log_named_uint("MARG price in IMD (1e18)", hook.margPriceInImd());
        assertLt(launchGas, 16_777_216);
    }

    function testNoteAboutImdOnTheHubPool() public {
        _launch();
        deal(IMD, alice, 1000 ether);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(router), type(uint256).max);
        T.NoteParams memory p;
        p.x = IMD;
        p.venue = T.Venue(T.VenueKind.UniV4, hook.HUB_POOL_ID(), address(0), false);
        p.side = T.Side.Buy;
        p.targetBps = 15_000;
        p.horizonDays = 30;
        p.class = uint8(T.Class.Declared);
        p.text = "IMD 1.5x in 30d: the hackathon launches are IMD-paired and every note here is an IMD buy";
        uint256 received = router.note(p, 20 ether, 1, block.timestamp + 1);
        vm.stopPrank();
        bytes32 id = bytes32(hook.noteCount());
        T.Note memory n = hook.noteOf(id);
        assertEq(n.author, alice);
        assertEq(n.x, IMD);
        assertApproxEqRel(n.postPrice, 1e18, 0.01e18); // IMD priced in IMD through the hub ≈ 1
        assertGt(received, 0);
        assertGt(n.deposit, 0);
        assertEq(hook.potImd(hook.today()), hook.STAMP());
        emit log_named_uint("MARG received for 20 IMD", received);
        emit log_named_uint("deposit (MARG)", n.deposit);
        emit log_named_uint("post price of IMD in IMD (1e18)", n.postPrice);
        // a quiet sell of half pays 3% to the pot
        uint256 potBefore = hook.potImd(hook.today());
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        router.sell(received / 2, 1, block.timestamp + 1);
        vm.stopPrank();
        assertGt(hook.potImd(hook.today()), potBefore);
    }
}
