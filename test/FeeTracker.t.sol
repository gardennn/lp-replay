// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {FeeTracker} from "../src/FeeTracker.sol";
import {Pools} from "../src/Pools.sol";
import {PositionSimulator} from "../src/PositionSimulator.sol";
import {FixedPoint128} from "../src/libraries/FixedPoint128.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @dev T3.4/3.5: two snapshots ~1000 blocks apart on ETH/USDC 0.05% — assert cumulative fees
///      are positive AND strictly smaller than the pool's global fee throughput over the same
///      window. The second assertion catches the kind of math bug where, e.g., a wrong unit
///      conversion makes our position look like it earned more than the entire pool.
contract FeeTrackerForkTest is Test {
    uint256 constant START_BLOCK = 19_000_000;
    uint256 constant END_BLOCK = 19_001_000;
    int24 constant TICK_SPACING = 10;
    int24 constant HALF_WIDTH = 2000;

    address constant POOL = Pools.ETH_USDC_005;

    FeeTracker tracker;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), START_BLOCK);
        tracker = new FeeTracker();
        // `vm.rollFork` wipes accounts that didn't exist at the target block; keep the tracker alive.
        vm.makePersistent(address(tracker));
    }

    function test_twoSnapshots_feesAreNonzeroAndBelowPoolTotal() public {
        (uint160 startSqrt, int24 startTick,,,,,) = IUniswapV3Pool(POOL).slot0();
        (int24 lower, int24 upper) = _centeredRange(startTick, HALF_WIDTH);

        // Position sized so price is in-range and both sides contribute.
        uint256 amount0 = 10_000e6; // USDC
        uint256 amount1 = 3 ether; // WETH
        uint128 L = PositionSimulator.computeLiquidity(startSqrt, lower, upper, amount0, amount1);
        assertGt(L, 0, "L must be > 0");

        // Pool global fee growth at start block — used later for the sanity bound.
        uint256 fg0Start = IUniswapV3Pool(POOL).feeGrowthGlobal0X128();
        uint256 fg1Start = IUniswapV3Pool(POOL).feeGrowthGlobal1X128();

        // Baseline snapshot.
        tracker.takeSnapshot(POOL, lower, upper, L);
        FeeTracker.Snapshot memory first = tracker.lastSnapshot();
        assertEq(first.cumulativeFee0, 0, "first snapshot fees must be zero");
        assertEq(first.cumulativeFee1, 0, "first snapshot fees must be zero");
        assertTrue(first.inRange, "starting position must be in range");

        // Roll forward ~4 hours of blocks.
        vm.rollFork(END_BLOCK);
        tracker.takeSnapshot(POOL, lower, upper, L);
        FeeTracker.Snapshot memory second = tracker.lastSnapshot();
        assertEq(second.blockNumber, END_BLOCK, "second snapshot block mismatch");

        // 1) Fees accrued (at least one side must be positive on a liquid pool like ETH/USDC 0.05%).
        assertTrue(
            second.cumulativeFee0 > 0 || second.cumulativeFee1 > 0, "expected fees > 0 on ETH/USDC over 1000 blocks"
        );

        // 2) Sanity: our fees strictly below the pool's upper-bound total fee throughput.
        //    Upper bound = delta_fgGlobal * current pool liquidity / Q128 — overestimates because
        //    liquidity in the pool has only grown over most ranges. If our number exceeds this,
        //    the inside-fee math is wrong.
        uint256 fg0End = IUniswapV3Pool(POOL).feeGrowthGlobal0X128();
        uint256 fg1End = IUniswapV3Pool(POOL).feeGrowthGlobal1X128();
        uint128 poolLiquidity = IUniswapV3Pool(POOL).liquidity();

        uint256 poolFees0Upper;
        uint256 poolFees1Upper;
        unchecked {
            poolFees0Upper = FullMath.mulDiv(fg0End - fg0Start, poolLiquidity, FixedPoint128.Q128);
            poolFees1Upper = FullMath.mulDiv(fg1End - fg1Start, poolLiquidity, FixedPoint128.Q128);
        }

        assertLt(second.cumulativeFee0, poolFees0Upper, "our token0 fees exceed pool upper bound");
        assertLt(second.cumulativeFee1, poolFees1Upper, "our token1 fees exceed pool upper bound");

        console2.log("our fee0 (USDC base units):", second.cumulativeFee0);
        console2.log("pool upper fee0:           ", poolFees0Upper);
        console2.log("our fee1 (WETH wei):       ", second.cumulativeFee1);
        console2.log("pool upper fee1:           ", poolFees1Upper);
    }

    /// @dev Calling `takeSnapshot` once with a range that *excludes* the current tick produces
    ///      `inRange=false` and zero fee growth for subsequent snapshots in that configuration.
    function test_outOfRange_accruesNoFees() public {
        (, int24 startTick,,,,,) = IUniswapV3Pool(POOL).slot0();

        // Put the whole range far below current price.
        int24 upper = _roundDown(startTick - 5000, TICK_SPACING);
        int24 lower = upper - 2000;
        uint256 amount1 = 3 ether;
        uint128 L;
        {
            (uint160 s,,,,,,) = IUniswapV3Pool(POOL).slot0();
            L = PositionSimulator.computeLiquidity(s, lower, upper, 0, amount1);
        }

        tracker.takeSnapshot(POOL, lower, upper, L);
        FeeTracker.Snapshot memory first = tracker.lastSnapshot();
        assertFalse(first.inRange);

        vm.rollFork(END_BLOCK);
        tracker.takeSnapshot(POOL, lower, upper, L);
        FeeTracker.Snapshot memory second = tracker.lastSnapshot();
        assertFalse(second.inRange);
        assertEq(second.cumulativeFee0, 0, "out-of-range should accrue nothing");
        assertEq(second.cumulativeFee1, 0, "out-of-range should accrue nothing");
    }

    function test_lastSnapshot_revertsWithNoSnapshots() public {
        FeeTracker fresh = new FeeTracker();
        vm.expectRevert(bytes("FeeTracker: no snapshots"));
        fresh.lastSnapshot();
    }

    function test_takeSnapshot_revertsOnInvertedRange() public {
        (, int24 startTick,,,,,) = IUniswapV3Pool(POOL).slot0();
        int24 lower = _roundDown(startTick - HALF_WIDTH, TICK_SPACING);
        int24 upper = _roundUp(startTick + HALF_WIDTH, TICK_SPACING);
        vm.expectRevert(bytes("FeeTracker: bad range"));
        tracker.takeSnapshot(POOL, upper, lower, 1);
    }

    // ---------- helpers ----------

    function _centeredRange(int24 tick, int24 halfWidth) private pure returns (int24 lower, int24 upper) {
        lower = _roundDown(tick - halfWidth, TICK_SPACING);
        upper = _roundUp(tick + halfWidth, TICK_SPACING);
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
