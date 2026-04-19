// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {Pools} from "../src/Pools.sol";
import {PositionSimulator} from "../src/PositionSimulator.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @dev Round-trip math validation: compute L from (amount0, amount1) at a real on-chain
///      sqrtPriceX96, then back out amounts from L. The binding side should match the input;
///      the non-binding side is allowed to show slack (that is real V3 behavior, not a bug).
contract PositionSimulatorForkTest is Test {
    uint256 constant FORK_BLOCK = 19_500_000;

    uint160 sqrtPriceX96;
    int24 currentTick;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(Pools.ETH_USDC_005).slot0();
        currentTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    /// @notice Narrow range (±10 ticks) → compound floor-rounding in `mulDiv` is sub-wei, so the
    ///         binding side round-trips within 1 wei, matching the T2.3 spec bar literally.
    function test_roundTrip_narrowRange_withinOneWei() public view {
        (int24 lower, int24 upper) = _centeredRange(10);

        uint256 amount0 = 100_000e6;
        uint256 amount1 = 1_000_000 ether; // absurd so amount0 binds

        uint128 L = PositionSimulator.computeLiquidity(sqrtPriceX96, lower, upper, amount0, amount1);
        (uint256 back0, uint256 back1) = PositionSimulator.computeAmounts(sqrtPriceX96, lower, upper, L);

        assertLe(back0, amount0);
        assertLe(back1, amount1);
        assertApproxEqAbs(back0, amount0, 1, "binding token0 off by >1 wei");
    }

    /// @notice Wide range (±2000 ticks): the same mulDiv-floor pattern allows a larger absolute
    ///         drift. Error is bounded by `(sqrtUpper − sqrtLower) / Q96`, which grows with range
    ///         width. We use a generous-but-tight absolute tolerance here.
    function test_roundTrip_wideRange_inRange_token0Binding() public view {
        (int24 lower, int24 upper) = _centeredRange(2000);
        uint256 amount0 = 30_000e6;
        uint256 amount1 = 1_000_000 ether;

        uint128 L = PositionSimulator.computeLiquidity(sqrtPriceX96, lower, upper, amount0, amount1);
        (uint256 back0, uint256 back1) = PositionSimulator.computeAmounts(sqrtPriceX96, lower, upper, L);

        assertLe(back0, amount0);
        assertLe(back1, amount1);
        assertApproxEqAbs(back0, amount0, 10, "binding token0 drift >10 wei on wide range");
        assertLt(back1, amount1, "non-binding side must show slack");
    }

    function test_roundTrip_wideRange_inRange_token1Binding() public view {
        (int24 lower, int24 upper) = _centeredRange(2000);
        uint256 amount0 = 1_000_000_000e6;
        uint256 amount1 = 10 ether;

        uint128 L = PositionSimulator.computeLiquidity(sqrtPriceX96, lower, upper, amount0, amount1);
        (uint256 back0, uint256 back1) = PositionSimulator.computeAmounts(sqrtPriceX96, lower, upper, L);

        assertLe(back0, amount0);
        assertLe(back1, amount1);
        // For 10 ether over a 4000-tick range, observed drift is ~400 wei on token1;
        // cap at 10_000 wei, which leaves 25x headroom for this range while catching real bugs.
        assertApproxEqAbs(back1, amount1, 10_000, "binding token1 drift too large");
        assertLt(back0, amount0, "non-binding side must show slack");
    }

    /// @notice Price below the range (tickLower > currentTick) → LP holds 100% token0.
    function test_outOfRange_aboveCurrentPrice_token0Only() public view {
        int24 lower = _roundUp(currentTick + 1000, 10);
        int24 upper = lower + 2000;

        uint256 amount0 = 50_000e6;
        uint128 L = PositionSimulator.computeLiquidity(sqrtPriceX96, lower, upper, amount0, 0);
        (uint256 back0, uint256 back1) = PositionSimulator.computeAmounts(sqrtPriceX96, lower, upper, L);

        assertEq(back1, 0, "no token1 when price below range");
        assertApproxEqAbs(back0, amount0, 1, "token0 should round-trip");
    }

    /// @notice Price above the range (tickUpper < currentTick) → LP holds 100% token1.
    function test_outOfRange_belowCurrentPrice_token1Only() public view {
        int24 upper = _roundDown(currentTick - 1000, 10);
        int24 lower = upper - 2000;

        uint256 amount1 = 5 ether;
        uint128 L = PositionSimulator.computeLiquidity(sqrtPriceX96, lower, upper, 0, amount1);
        (uint256 back0, uint256 back1) = PositionSimulator.computeAmounts(sqrtPriceX96, lower, upper, L);

        assertEq(back0, 0, "no token0 when price above range");
        assertApproxEqAbs(back1, amount1, 10_000, "token1 off by >10k wei on wide range");
    }

    function test_revertsOnInvertedRange() public {
        vm.expectRevert(bytes("PositionSimulator: bad range"));
        this.extComputeLiquidity(sqrtPriceX96, int24(100), int24(-100), 1 ether, 1 ether);
    }

    // ---------- external wrappers (needed so vm.expectRevert sees a lower call frame) ----------

    function extComputeLiquidity(
        uint160 sqrtPriceX96_,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128) {
        return PositionSimulator.computeLiquidity(sqrtPriceX96_, tickLower, tickUpper, amount0, amount1);
    }

    // ---------- helpers ----------

    function _centeredRange(int24 halfWidth) private view returns (int24 lower, int24 upper) {
        lower = _roundDown(currentTick - halfWidth, 10);
        upper = _roundUp(currentTick + halfWidth, 10);
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
