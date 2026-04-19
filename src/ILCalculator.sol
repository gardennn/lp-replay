// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Impermanent-loss calculator. IL is defined as the value of the (rebalanced)
///         position at `endBlock` minus the value the same starting tokens would have had
///         if simply held (HODL).
/// @dev Negative return = LP underperformed HODL. Fees are **not** included here — the
///      orchestrator adds them on top to produce net P&L. Matches the convention in
///      `.specs/02-PLAN.md` ("Impermanent loss" section).
library ILCalculator {
    /// @notice IL in 1e18 USD, signed.
    /// @param startAmount0 Token0 amount deposited, in token0 base units (e.g. USDC 1e6).
    /// @param startAmount1 Token1 amount deposited, in token1 base units (e.g. WETH 1e18).
    /// @param finalAmount0 Token0 amount the position would redeem at the close price.
    /// @param finalAmount1 Token1 amount the position would redeem at the close price.
    /// @param price0InUsd USD (1e18-fixed) per one base unit of token0.
    /// @param price1InUsd USD (1e18-fixed) per one base unit of token1.
    function impermanentLossUSD(
        uint256 startAmount0,
        uint256 startAmount1,
        uint256 finalAmount0,
        uint256 finalAmount1,
        uint256 price0InUsd,
        uint256 price1InUsd
    ) internal pure returns (int256 ilUsd1e18) {
        uint256 hodlUsd = startAmount0 * price0InUsd + startAmount1 * price1InUsd;
        uint256 finalUsd = finalAmount0 * price0InUsd + finalAmount1 * price1InUsd;

        // Both are <= ~1e60 in any realistic scenario (amount * price both fit in ~2e40),
        // well within int256 range (~5.78e76). If either overflows, revert — bug-ish input.
        require(hodlUsd <= uint256(type(int256).max), "ILCalculator: hodl overflow");
        require(finalUsd <= uint256(type(int256).max), "ILCalculator: final overflow");

        ilUsd1e18 = int256(finalUsd) - int256(hodlUsd);
    }
}
