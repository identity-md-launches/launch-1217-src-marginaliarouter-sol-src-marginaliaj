// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";

interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface IUniswapV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

/// @notice Read-only price adapters. Every price is "quote per 1e18 of X", 1e18 scaled, and assumes
/// 18-decimal assets on both sides (IMD, MARG, WETH and the launch tokens all are; a non-18 X is a
/// documented v1 limitation).
library PriceAdapters {
    using StateLibrary for IPoolManager;

    error UnsupportedVenue();
    error EmptyPool();

    uint256 internal constant Q96 = 2 ** 96;

    function priceInQuote(IPoolManager manager, T.Venue memory v) internal view returns (uint256) {
        if (v.kind == T.VenueKind.UniV4) {
            (uint160 sqrtP,,,) = manager.getSlot0(PoolId.wrap(v.ref));
            return fromSqrt(sqrtP, v.xIsToken0);
        }
        if (v.kind == T.VenueKind.UniV3) {
            (uint160 sqrtP,,,,,,) = IUniswapV3PoolMinimal(address(uint160(uint256(v.ref)))).slot0();
            return fromSqrt(sqrtP, v.xIsToken0);
        }
        if (v.kind == T.VenueKind.UniV2) {
            (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(address(uint160(uint256(v.ref)))).getReserves();
            if (r0 == 0 || r1 == 0) revert EmptyPool();
            return v.xIsToken0 ? FullMath.mulDiv(r1, 1e18, r0) : FullMath.mulDiv(r0, 1e18, r1);
        }
        revert UnsupportedVenue();
    }

    /// @dev price of token0 in token1 = sqrtP^2 / 2^192; inverted when X is token1.
    function fromSqrt(uint160 sqrtP, bool xIsToken0) internal pure returns (uint256) {
        if (sqrtP == 0) revert EmptyPool();
        uint256 p = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        p = FullMath.mulDiv(p, 1e18, Q96);
        if (xIsToken0) return p;
        if (p == 0) revert EmptyPool();
        return FullMath.mulDiv(1e18, 1e18, p);
    }
}
