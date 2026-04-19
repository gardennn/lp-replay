// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @notice Pure math for opening/closing a virtual Uniswap V3 position.
/// @dev No state, no transfers. We don't mint a real NFT — we just track `L` and translate
///      to/from token amounts on demand. All math is raw integer; callers decimal-adjust.
library PositionSimulator {
    /// @notice Liquidity `L` minted when depositing (amount0, amount1) across [tickLower, tickUpper]
    ///         at the current price `sqrtPriceX96`.
    /// @dev Mirrors `NonfungiblePositionManager.mint`'s liquidity computation. If the current
    ///      price is outside the range, only one side's amount is binding.
    function computeLiquidity(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        require(tickLower < tickUpper, "PositionSimulator: bad range");
        uint160 sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1);
    }

    /// @notice Token amounts that `liquidity` would redeem to at price `sqrtPriceX96` across
    ///         [tickLower, tickUpper]. The inverse of `computeLiquidity` up to rounding.
    /// @dev When the price is outside the range, one of `amount0`/`amount1` will be zero — that
    ///      is the correct behavior, not a bug.
    function computeAmounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        require(tickLower < tickUpper, "PositionSimulator: bad range");
        uint160 sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
    }
}
