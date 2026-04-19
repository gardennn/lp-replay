// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint128} from "./libraries/FixedPoint128.sol";

/// @notice Snapshots Uniswap V3 fee growth over time and converts it to token amounts for a
///         virtual position of constant liquidity `L` over `[tickLower, tickUpper]`.
/// @dev Approach: for each interval between snapshots where the position was in-range, accrue
///      `L * (feeGrowthGlobal_new - feeGrowthGlobal_prev) / 2^128`. This is identical to the
///      V3 §6.3 `feeGrowthInside` delta when the position stays continuously in-range, but is
///      robust to boundary-tick re-initialization (when another LP mints/burns at our exact
///      boundary, the pool's `f_o` flips and a naive `feeGrowthInside` delta would wrap
///      around uint256). `feeGrowthInside` is still recorded in each snapshot for inspection.
///
///      Approximations: (1) intervals where prev.inRange is true accrue full-period fees even
///      if the position briefly exited; (2) we don't dilute pool liquidity by our own L, so
///      this overstates fees by a factor of L_active/(L_active + L) — negligible for any
///      realistic deposit on a deep pool.
contract FeeTracker {
    struct Snapshot {
        uint256 blockNumber;
        int24 tick;
        uint160 sqrtPriceX96;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        uint256 cumulativeFee0;
        uint256 cumulativeFee1;
        bool inRange;
    }

    Snapshot[] private _snapshots;

    /// @notice Reads pool state at the current block and appends a snapshot. The first call
    ///         establishes a baseline (zero fees); subsequent calls accrue
    ///         `L * (fg_new - fg_prev) / 2^128` to the running totals when the previous
    ///         snapshot was in-range.
    function takeSnapshot(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (Snapshot memory snap)
    {
        require(tickLower < tickUpper, "FeeTracker: bad range");

        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = p.slot0();
        uint256 fg0 = p.feeGrowthGlobal0X128();
        uint256 fg1 = p.feeGrowthGlobal1X128();
        (uint256 fgi0, uint256 fgi1) = _computeFeeGrowthInside(pool, tickLower, tickUpper, tick);

        uint256 cumFee0;
        uint256 cumFee1;
        if (_snapshots.length > 0) {
            Snapshot storage prev = _snapshots[_snapshots.length - 1];
            cumFee0 = prev.cumulativeFee0;
            cumFee1 = prev.cumulativeFee1;
            if (prev.inRange) {
                unchecked {
                    uint256 dFg0 = fg0 - prev.feeGrowthGlobal0X128;
                    uint256 dFg1 = fg1 - prev.feeGrowthGlobal1X128;
                    cumFee0 += FullMath.mulDiv(dFg0, liquidity, FixedPoint128.Q128);
                    cumFee1 += FullMath.mulDiv(dFg1, liquidity, FixedPoint128.Q128);
                }
            }
        }

        snap = Snapshot({
            blockNumber: block.number,
            tick: tick,
            sqrtPriceX96: sqrtPriceX96,
            feeGrowthGlobal0X128: fg0,
            feeGrowthGlobal1X128: fg1,
            feeGrowthInside0X128: fgi0,
            feeGrowthInside1X128: fgi1,
            cumulativeFee0: cumFee0,
            cumulativeFee1: cumFee1,
            inRange: tick >= tickLower && tick < tickUpper
        });
        _snapshots.push(snap);
    }

    // ---------- views ----------

    function snapshotCount() external view returns (uint256) {
        return _snapshots.length;
    }

    function snapshotAt(uint256 i) external view returns (Snapshot memory) {
        return _snapshots[i];
    }

    function lastSnapshot() external view returns (Snapshot memory) {
        require(_snapshots.length > 0, "FeeTracker: no snapshots");
        return _snapshots[_snapshots.length - 1];
    }

    /// @dev Exposed for tests. Matches V3 whitepaper §6.3 semantics.
    function computeFeeGrowthInside(address pool, int24 tickLower, int24 tickUpper, int24 currentTick)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        return _computeFeeGrowthInside(pool, tickLower, tickUpper, currentTick);
    }

    // ---------- internals ----------

    /// @dev V3 whitepaper §6.3. Given the global accumulator `f_g` and each boundary tick's
    ///      `f_o`, the fee growth inside the range is `f_g - below(lower) - above(upper)`,
    ///      where `below`/`above` flip sides based on `currentTick`.
    function _computeFeeGrowthInside(address pool, int24 tickLower, int24 tickUpper, int24 currentTick)
        private
        view
        returns (uint256 fgi0, uint256 fgi1)
    {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        uint256 fg0 = p.feeGrowthGlobal0X128();
        uint256 fg1 = p.feeGrowthGlobal1X128();

        (,, uint256 lowerOut0, uint256 lowerOut1,,,,) = p.ticks(tickLower);
        (,, uint256 upperOut0, uint256 upperOut1,,,,) = p.ticks(tickUpper);

        uint256 below0;
        uint256 below1;
        uint256 above0;
        uint256 above1;

        if (currentTick >= tickLower) {
            below0 = lowerOut0;
            below1 = lowerOut1;
        } else {
            unchecked {
                below0 = fg0 - lowerOut0;
                below1 = fg1 - lowerOut1;
            }
        }

        if (currentTick < tickUpper) {
            above0 = upperOut0;
            above1 = upperOut1;
        } else {
            unchecked {
                above0 = fg0 - upperOut0;
                above1 = fg1 - upperOut1;
            }
        }

        unchecked {
            fgi0 = fg0 - below0 - above0;
            fgi1 = fg1 - below1 - above1;
        }
    }
}
