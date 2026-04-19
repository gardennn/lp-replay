// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {LPBacktest} from "../src/LPBacktest.sol";
import {Pools} from "../src/Pools.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @dev End-to-end integration: run a ~10-day backtest on ETH/USDC 0.05% and verify the Result
///      is internally consistent (positive fees, non-zero HODL, non-zero P&L, snapshot count
///      matches the 7200-blocks-per-day cadence).
contract LPBacktestIntegrationTest is Test {
    uint256 constant START_BLOCK = 19_000_000; // 2024-01-13
    uint256 constant END_BLOCK = 19_072_000; // 2024-01-23 (10 × 7200 blocks later)
    int24 constant TICK_SPACING = 10;
    int24 constant HALF_WIDTH = 2000;

    LPBacktest backtest;
    int24 lower;
    int24 upper;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), START_BLOCK);
        (, int24 startTick,,,,,) = IUniswapV3Pool(Pools.ETH_USDC_005).slot0();
        lower = _roundDown(startTick - HALF_WIDTH, TICK_SPACING);
        upper = _roundUp(startTick + HALF_WIDTH, TICK_SPACING);
        backtest = new LPBacktest();
    }

    function test_shortWindow_ethUsdc_returnsConsistentResult() public {
        LPBacktest.Config memory cfg = LPBacktest.Config({
            pool: Pools.ETH_USDC_005,
            startBlock: START_BLOCK,
            endBlock: END_BLOCK,
            amount0: 10_000e6, // USDC
            amount1: 3 ether, // WETH
            tickLower: lower,
            tickUpper: upper
        });

        LPBacktest.Result memory r = backtest.run(cfg);

        // --- Structural ---
        // Cadence: baseline (1) + intermediate dailies + final (1) = ceil(blocks/day) + 1.
        // 72_000 / 7200 = 10, so intermediates = 9, total = 11.
        assertEq(r.snapshots.length, 11, "expected 11 snapshots (baseline + 9 daily + final)");
        assertEq(r.daysInRange + r.daysOutOfRange, r.snapshots.length, "days must sum to total");

        // --- Economic sanity ---
        assertGt(r.hodlValueUSD, 0, "hodl value must be positive");
        assertGt(r.finalAmount0 + r.finalAmount1, 0, "position must not be drained");
        assertTrue(r.totalFees0 > 0 || r.totalFees1 > 0, "liquid pool should accrue fees");
        assertGt(r.feesUSD, 0, "feesUSD must be positive given fee accrual");
        assertTrue(r.netPnlUSD != 0, "netPnlUSD must be non-zero after 10 days of swaps");

        // --- Sign check ---
        // Between 2024-01-13 and 2024-01-23 ETH fell from ~$2560 → ~$2190 (-14%) in the post-
        // ETF-approval drawdown. A symmetric in-range LP buys WETH on the way down, ending with
        // more (now-cheaper) WETH than the HODL baseline → position worth less than HODL. IL < 0.
        assertLt(r.ilUSD, 0, "in-range LP through a drawdown should produce IL < 0");

        // --- Identity: netPnlUSD == ilUSD + feesUSD ---
        assertEq(r.netPnlUSD, r.ilUSD + int256(r.feesUSD), "net P&L identity broken");

        console2.log("hodl USD (1e18):         ", r.hodlValueUSD);
        console2.log("fees USD (1e18):         ", r.feesUSD);
        console2.log("IL USD   (1e18, signed): ", r.ilUSD);
        console2.log("net P&L  (1e18, signed): ", r.netPnlUSD);
        console2.log("APR bps (signed):        ", r.aprBps);
        console2.log("days in range:           ", r.daysInRange);
        console2.log("days out of range:       ", r.daysOutOfRange);
    }

    function test_run_revertsOnBadWindow() public {
        LPBacktest.Config memory cfg = LPBacktest.Config({
            pool: Pools.ETH_USDC_005,
            startBlock: END_BLOCK,
            endBlock: START_BLOCK,
            amount0: 10_000e6,
            amount1: 3 ether,
            tickLower: lower,
            tickUpper: upper
        });
        vm.expectRevert(bytes("LPBacktest: bad window"));
        backtest.run(cfg);
    }

    function test_run_revertsOnInvertedRange() public {
        LPBacktest.Config memory cfg = LPBacktest.Config({
            pool: Pools.ETH_USDC_005,
            startBlock: START_BLOCK,
            endBlock: END_BLOCK,
            amount0: 10_000e6,
            amount1: 3 ether,
            tickLower: upper,
            tickUpper: lower
        });
        vm.expectRevert(bytes("LPBacktest: bad range"));
        backtest.run(cfg);
    }

    function test_run_revertsOnZeroLiquidity() public {
        LPBacktest.Config memory cfg = LPBacktest.Config({
            pool: Pools.ETH_USDC_005,
            startBlock: START_BLOCK,
            endBlock: END_BLOCK,
            amount0: 0,
            amount1: 0,
            tickLower: lower,
            tickUpper: upper
        });
        vm.expectRevert(bytes("LPBacktest: zero liquidity"));
        backtest.run(cfg);
    }

    /// @dev WBTC/WETH pool exercises the `_sqrtPriceX96ToRatio1e18` path. WBTC sqrtPriceX96
    ///      lands around 4e34, which overflows the naive `sqrt*sqrt*1e18` form; the FullMath
    ///      version stays correct. This test guards the regression: if the pricing reverts on
    ///      overflow, `run()` aborts and the test fails.
    function test_run_wbtcEth_pricesWithoutOverflow() public {
        (, int24 startTick,,,,,) = IUniswapV3Pool(Pools.WBTC_ETH_030).slot0();
        // WBTC/ETH 0.30% pool tick spacing = 60.
        int24 tickSpacing = 60;
        int24 wbtcLower = _roundDown(startTick - 6_000, tickSpacing);
        int24 wbtcUpper = _roundUp(startTick + 6_000, tickSpacing);

        LPBacktest.Config memory cfg = LPBacktest.Config({
            pool: Pools.WBTC_ETH_030,
            startBlock: START_BLOCK,
            endBlock: START_BLOCK + 7200, // 1 day
            amount0: 1e8, // 1 WBTC
            amount1: 25 ether, // approx peer side
            tickLower: wbtcLower,
            tickUpper: wbtcUpper
        });

        LPBacktest.Result memory r = backtest.run(cfg);
        assertGt(r.hodlValueUSD, 0, "WBTC pricing must produce positive USD value");
        assertGt(r.snapshots.length, 1, "must have baseline + final");
    }

    // ---------- helpers ----------

    function _roundDown(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _roundUp(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }
}
