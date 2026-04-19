// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {LPBacktest} from "../../src/LPBacktest.sol";
import {Pools} from "../../src/Pools.sol";
import {Fmt} from "../utils/Fmt.sol";

/// @notice Reference scenario T5.1 — wide-range ETH/USDC LP across May 4 → Jun 29 2024 (~55 days).
/// @dev    Range: ±2000 ticks (~±22%) around the entry tick. Deposit: 30k USDC + 10 WETH.
///         No hard P&L assertions — this scenario exists to print a full Result for the README
///         and to be paired with T5.2 (narrow) for the strategy comparison doc.
contract ETH_USDC_Wide_May2024 is Test {
    uint256 constant START_BLOCK = 19_800_000; // 2024-05-04
    uint256 constant END_BLOCK = 20_200_000; // 2024-06-29
    int24 constant TICK_SPACING = 10;
    int24 constant HALF_WIDTH = 2000;

    function test_wideRange_ethUsdc_logsResult() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), START_BLOCK);
        (, int24 startTick,,,,,) = IUniswapV3Pool(Pools.ETH_USDC_005).slot0();
        int24 lower = _roundDown(startTick - HALF_WIDTH, TICK_SPACING);
        int24 upper = _roundUp(startTick + HALF_WIDTH, TICK_SPACING);

        LPBacktest backtest = new LPBacktest();
        LPBacktest.Result memory r = backtest.run(
            LPBacktest.Config({
                pool: Pools.ETH_USDC_005,
                startBlock: START_BLOCK,
                endBlock: END_BLOCK,
                amount0: 30_000e6,
                amount1: 10 ether,
                tickLower: lower,
                tickUpper: upper
            })
        );

        // Structural sanity.
        assertGt(r.snapshots.length, 1, "must have at least baseline + final");
        assertEq(r.daysInRange + r.daysOutOfRange, r.snapshots.length, "days must sum to total");
        assertGt(r.hodlValueUSD, 0, "hodl value must be positive");
        assertEq(r.netPnlUSD, r.ilUSD + int256(r.feesUSD), "net P&L identity broken");

        console2.log("=== T5.1 wide-range ETH/USDC (HALF_WIDTH=2000) ===");
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
