// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {FullMath} from "./libraries/FullMath.sol";
import {Pools} from "./Pools.sol";

/// @notice Reads ETH/USD from the Uniswap V3 USDC/WETH 0.05% pool's `slot0`.
/// @dev No Chainlink, no TWAP — just the pool's current `sqrtPriceX96`. Fine for backtests
///      where we fork at historical blocks; unsafe as a live oracle.
contract PriceOracle {
    /// @notice Returns ETH/USD at the currently forked block, as 1e18 fixed-point USD-per-ETH.
    /// @dev Pool is USDC/WETH 0.05%. token0 = USDC (6 decimals), token1 = WETH (18 decimals).
    ///      sqrtPriceX96 encodes sqrt(token1_wei / token0_wei) * 2^96.
    ///      USD-per-ETH in 1e18 = 10^30 * 2^192 / sqrtPriceX96^2
    ///      (10^30 = 10^18 USD scale * 10^12 decimal adjustment from USDC's 6 → 18.)
    function getEthUsd() public view returns (uint256 ethUsd1e18) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(Pools.ETH_USDC_005).slot0();
        ethUsd1e18 = _sqrtPriceX96ToEthUsd(sqrtPriceX96);
    }

    /// @notice Same as `getEthUsd()` but asserts the caller's expected block matches the fork.
    /// @dev Signature mirrors the spec (T1.2). Using this in tests catches "forgot to roll" bugs.
    function getEthUsdAtBlock(uint256 blockNumber) external view returns (uint256) {
        require(block.number == blockNumber, "PriceOracle: fork not at expected block");
        return getEthUsd();
    }

    /// @dev Branches at sqrtPriceX96 = 2^128 to keep the squared value within uint256.
    ///      Pattern adapted from v3-periphery's OracleLibrary.getQuoteAtTick.
    function _sqrtPriceX96ToEthUsd(uint160 sqrtPriceX96) private pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            return FullMath.mulDiv(1e30, 1 << 192, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return FullMath.mulDiv(1e30, 1 << 128, ratioX128);
        }
    }
}
