// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {LPBacktest} from "../../src/LPBacktest.sol";
import {Pools} from "../../src/Pools.sol";
import {Fmt} from "../utils/Fmt.sol";

/// @notice Reference scenario T5.3 — USDC/USDT 0.01% stable pool, tight range around the entry
///         tick. Same window as T5.1/T5.2 (May 4 → Jun 29 2024).
/// @dev    Tick spacing on the 0.01% pool is 1, so HALF_WIDTH=10 ticks ≈ ±0.1% — a realistic
///         "stable LP" range. Both tokens are 6-decimal stables; with the LPBacktest oracle
///         hardcoding USDC and USDT to $1, IL should be ~$0 except for any tiny price drift the
///         pool itself records, and fees should be the dominant signal.
contract USDC_USDT_Stable is Test {
    uint256 constant START_BLOCK = 19_800_000; // 2024-05-04
    uint256 constant END_BLOCK = 20_200_000; // 2024-06-29
    int24 constant TICK_SPACING = 1;
    int24 constant HALF_WIDTH = 10;

    function test_stable_usdcUsdt_logsResult() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), START_BLOCK);
        (, int24 startTick,,,,,) = IUniswapV3Pool(Pools.USDC_USDT_001).slot0();
        int24 lower = _roundDown(startTick - HALF_WIDTH, TICK_SPACING);
        int24 upper = _roundUp(startTick + HALF_WIDTH, TICK_SPACING);

        LPBacktest backtest = new LPBacktest();
        LPBacktest.Result memory r = backtest.run(
            LPBacktest.Config({
                pool: Pools.USDC_USDT_001,
                startBlock: START_BLOCK,
                endBlock: END_BLOCK,
                amount0: 100_000e6, // USDC
                amount1: 100_000e6, // USDT
                tickLower: lower,
                tickUpper: upper
            })
        );

        assertGt(r.snapshots.length, 1, "must have at least baseline + final");
        assertEq(r.daysInRange + r.daysOutOfRange, r.snapshots.length, "days must sum to total");
        assertGt(r.hodlValueUSD, 0, "hodl value must be positive");
        assertEq(r.netPnlUSD, r.ilUSD + int256(r.feesUSD), "net P&L identity broken");

        console2.log("=== T5.3 stable USDC/USDT (HALF_WIDTH=10) ===");
        console2.log("entry tick:              ", startTick);
        console2.log("range tick lower:        ", lower);
        console2.log("range tick upper:        ", upper);
        console2.log("snapshots:               ", r.snapshots.length);
        console2.log("days in range:           ", r.daysInRange);
        console2.log("days out of range:       ", r.daysOutOfRange);
        console2.log(
            string.concat("hodl USD (1e18):          ", Fmt.toStr(r.hodlValueUSD), "   (", Fmt.usd(r.hodlValueUSD), ")")
        );
        console2.log(string.concat("fees USD (1e18):          ", Fmt.toStr(r.feesUSD), "   (", Fmt.usd(r.feesUSD), ")"));
        console2.log(string.concat("IL USD   (1e18, signed):  ", Fmt.toIStr(r.ilUSD), "   (", Fmt.iusd(r.ilUSD), ")"));
        console2.log(
            string.concat("net P&L  (1e18, signed):  ", Fmt.toIStr(r.netPnlUSD), "   (", Fmt.iusd(r.netPnlUSD), ")")
        );
        console2.log(
            string.concat("APR bps (signed):         ", Fmt.toIStr(r.aprBps), "   (", Fmt.aprPct(r.aprBps), ")")
        );
    }

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
