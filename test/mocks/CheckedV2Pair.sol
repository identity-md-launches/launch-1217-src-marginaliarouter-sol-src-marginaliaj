// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Offline v2 pair model: stored reserves, actual input detection, 0.3% fee and K check.
/// It deliberately omits LP shares, TWAP accumulators and flash swaps, unused by the companion router.
contract CheckedV2Pair {
    using SafeERC20 for IERC20;
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function sync() public {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "reserve overflow");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata data) external {
        require(data.length == 0, "flash swap not modeled");
        require(out0 + out1 > 0 && out0 < reserve0 && out1 < reserve1, "invalid output");
        if (out0 > 0) IERC20(token0).safeTransfer(to, out0);
        if (out1 > 0) IERC20(token1).safeTransfer(to, out1);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - out0 ? b0 - (reserve0 - out0) : 0;
        uint256 in1 = b1 > reserve1 - out1 ? b1 - (reserve1 - out1) : 0;
        require(in0 + in1 > 0, "no input");
        require(
            (b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= uint256(reserve0) * reserve1 * 1_000_000,
            "K decreased"
        );
        sync();
    }
}
