// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
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
import {MarginaliaJudge} from "../../src/MarginaliaJudge.sol";
import {MarginaliaTreasury} from "../../src/MarginaliaTreasury.sol";
import {MarginaliaImpls} from "../../src/MarginaliaImpls.sol";

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

    address requester = makeAddr("marginalia-rehearsal-requester");
    address alice = makeAddr("marginalia-rehearsal-alice");
    Marginalia token;
    MarginaliaHook hook;
    MarginaliaRouter router;
    PoolKey key;
    uint256 launchGas;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        // A derived test address must not land on a live mainnet contract (makeAddr("alice") does).
        assertEq(alice.code.length, 0, "alice must be an EOA on the fork");
        assertEq(requester.code.length, 0, "requester must be an EOA on the fork");
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
        // On mainnet the implementations come from the preceding contracts-only launch; here they are etched.
        vm.etch(MarginaliaImpls.ROUTER_IMPL, address(new MarginaliaRouter()).code);
        vm.etch(MarginaliaImpls.JUDGE_IMPL, address(new MarginaliaJudge()).code);
        vm.etch(MarginaliaImpls.TREASURY_IMPL, address(new MarginaliaTreasury()).code);
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

    function testTradeAndNoteSellsImdOnTheHubPool() public {
        _launch();
        deal(IMD, alice, 1000 ether);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(router), type(uint256).max);
        PoolKey memory hub = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10000, 200, IHooks(address(0)));
        assertEq(PoolId.unwrap(hub.toId()), hook.HUB_POOL_ID(), "hub key");
        MarginaliaRouter.XTrade memory x =
            MarginaliaRouter.XTrade(router.X_V4(), hub, false, address(0), IMD, 10 ether, 1); // sell IMD for ETH
        T.NoteParams memory p;
        p.x = IMD;
        p.venue = T.Venue(T.VenueKind.UniV4, hook.HUB_POOL_ID(), address(0), false);
        p.side = T.Side.Sell;
        p.targetBps = 7000;
        p.horizonDays = 14;
        p.class = uint8(T.Class.Declared);
        p.text = "IMD -30% in 14d: launch-night sells into a thin hub";
        uint256 ethBefore = alice.balance;
        router.tradeAndNote(x, p, 5 ether, 1, block.timestamp + 1);
        vm.stopPrank();
        assertGt(alice.balance, ethBefore, "received ETH for the IMD sold");
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertEq(n.x, IMD);
        assertEq(n.postBalance, IERC20(IMD).balanceOf(alice));
        // a traded note about a token other than the one traded is refused
        p.x = address(token);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(key.toId()), IMD, address(token) < IMD);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.NoteTokenMismatch.selector);
        router.tradeAndNote(x, p, 5 ether, 1, block.timestamp + 1);
        vm.stopPrank();
    }

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    function _xNote(address xToken, T.Venue memory venue, uint32 targetBps, uint16 horizon, string memory text)
        internal
        pure
        returns (T.NoteParams memory p)
    {
        p.x = xToken;
        p.venue = venue;
        p.side = T.Side.Buy;
        p.targetBps = targetBps;
        p.horizonDays = horizon;
        p.class = uint8(T.Class.Declared);
        p.text = text;
    }

    /// @dev Buy LINK with WETH on the live Uniswap v3 LINK/WETH 0.3% pool and post the call in one tx.
    function testTradeAndNoteOnUniswapV3() public {
        _launch();
        address v3Pool = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;
        deal(IMD, alice, 1000 ether);
        deal(WETH, alice, 5 ether);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        PoolKey memory noKey;
        MarginaliaRouter.XTrade memory x = MarginaliaRouter.XTrade(router.X_V3(), noKey, false, v3Pool, WETH, 1 ether, 1);
        T.NoteParams memory p = _xNote(
            LINK,
            T.Venue(T.VenueKind.UniV3, bytes32(uint256(uint160(v3Pool))), WETH, LINK < WETH),
            15_000,
            30,
            "LINK 1.5x in 30d: CCIP volume"
        );
        uint256 linkBefore = IERC20(LINK).balanceOf(alice);
        router.tradeAndNote(x, p, 5 ether, 1, block.timestamp + 1);
        vm.stopPrank();
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertGt(IERC20(LINK).balanceOf(alice), linkBefore, "bought LINK");
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertEq(n.x, LINK);
        assertEq(n.postBalance, IERC20(LINK).balanceOf(alice));
        assertGt(n.postPrice, 0);
        emit log_named_uint("LINK price in IMD (1e18)", n.postPrice);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds nothing");
    }

    /// @dev Buy UNI with WETH on the live Uniswap v2 UNI/WETH pair and post the call in one tx.
    function testTradeAndNoteOnUniswapV2() public {
        _launch();
        address pair = 0xd3d2E2692501A5c9Ca623199D38826e513033a17;
        deal(IMD, alice, 1000 ether);
        deal(WETH, alice, 5 ether);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        PoolKey memory noKey;
        MarginaliaRouter.XTrade memory x = MarginaliaRouter.XTrade(router.X_V2(), noKey, false, pair, WETH, 1 ether, 1);
        T.NoteParams memory p = _xNote(
            UNI, T.Venue(T.VenueKind.UniV2, bytes32(uint256(uint160(pair))), WETH, UNI < WETH), 12_000, 14, "UNI +20% in 14d: fee switch"
        );
        uint256 uniBefore = IERC20(UNI).balanceOf(alice);
        router.tradeAndNote(x, p, 5 ether, 1, block.timestamp + 1);
        vm.stopPrank();
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertGt(IERC20(UNI).balanceOf(alice), uniBefore, "bought UNI");
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertEq(n.x, UNI);
        assertGt(n.postPrice, 0);
        emit log_named_uint("UNI price in IMD (1e18)", n.postPrice);
        // the wrong subject is refused on the v2 path too
        p.x = LINK;
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.NoteTokenMismatch.selector);
        router.tradeAndNote(x, p, 5 ether, 1, block.timestamp + 1);
        vm.stopPrank();
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
        assertEq(hook.refundPool(hook.today()) + hook.leaderboardPool(hook.week()) + hook.thesisPool(hook.week()), hook.STAMP());
        emit log_named_uint("MARG received for 20 IMD", received);
        emit log_named_uint("deposit (MARG)", n.deposit);
        emit log_named_uint("post price of IMD in IMD (1e18)", n.postPrice);
    }
}
