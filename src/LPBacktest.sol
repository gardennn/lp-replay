// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

import {FeeTracker} from "./FeeTracker.sol";
import {ILCalculator} from "./ILCalculator.sol";
import {Pools} from "./Pools.sol";
import {PositionSimulator} from "./PositionSimulator.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @notice Top-level backtest orchestrator: given a pool, a window, deposit amounts, and a tick
///         range, rolls the forked chain block-by-block (one snapshot per day) and returns
///         net P&L vs HODL.
/// @dev Uses Foundry cheatcodes (`vm.rollFork`, `vm.makePersistent`). Only runs in a test
///      environment; attempting to deploy this on a live network will succeed but any call to
///      `run()` will revert on the first cheatcode invocation.
contract LPBacktest {
    /// @dev Cheatcode address — same pattern Foundry uses internally.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev ~1 snapshot per day on Ethereum mainnet (12s/block × 7200 ≈ 24h).
    ///      Documented as the T4.3 choice: dense enough to distinguish in-range vs out-of-range
    ///      days, sparse enough to keep fork roll counts bounded on Alchemy free tier.
    uint256 internal constant BLOCKS_PER_DAY = 7200;

    struct Config {
        address pool;
        uint256 startBlock;
        uint256 endBlock;
        uint256 amount0;
        uint256 amount1;
        int24 tickLower;
        int24 tickUpper;
    }

    struct Result {
        uint256 finalAmount0;
        uint256 finalAmount1;
        uint256 totalFees0;
        uint256 totalFees1;
        uint256 feesUSD;
        int256 ilUSD;
        int256 netPnlUSD;
        uint256 hodlValueUSD;
        uint256 daysInRange;
        uint256 daysOutOfRange;
        int256 aprBps;
        FeeTracker.Snapshot[] snapshots;
    }

    PriceOracle private immutable priceOracle;

    constructor() {
        priceOracle = new PriceOracle();
        vm.makePersistent(address(priceOracle));
        vm.makePersistent(address(this));
    }

    /// @notice Runs the full backtest across [startBlock, endBlock].
    function run(Config calldata config) external returns (Result memory result) {
        require(config.startBlock < config.endBlock, "LPBacktest: bad window");
        require(config.tickLower < config.tickUpper, "LPBacktest: bad range");

        // 1) Snap to the start block and read entry price.
        vm.rollFork(config.startBlock);
        IUniswapV3Pool pool = IUniswapV3Pool(config.pool);
        (uint160 sqrtStart,,,,,,) = pool.slot0();

        // 2) Compute constant liquidity L for the deposit. `getLiquidityForAmounts` takes the
        //    binding side and leaves any excess of the non-binding token undeposited; we hold
        //    that excess as idle cash so the HODL comparison stays apples-to-apples.
        uint128 L = PositionSimulator.computeLiquidity(
            sqrtStart, config.tickLower, config.tickUpper, config.amount0, config.amount1
        );
        require(L > 0, "LPBacktest: zero liquidity");
        (uint256 deposited0, uint256 deposited1) =
            PositionSimulator.computeAmounts(sqrtStart, config.tickLower, config.tickUpper, L);
        uint256 leftover0 = config.amount0 - deposited0;
        uint256 leftover1 = config.amount1 - deposited1;

        // 3) Spin up a fee tracker that survives fork rolls.
        FeeTracker tracker = new FeeTracker();
        vm.makePersistent(address(tracker));

        // 4) Baseline + daily snapshots + final snapshot at endBlock.
        tracker.takeSnapshot(config.pool, config.tickLower, config.tickUpper, L);
        uint256 next = config.startBlock + BLOCKS_PER_DAY;
        while (next < config.endBlock) {
            vm.rollFork(next);
            tracker.takeSnapshot(config.pool, config.tickLower, config.tickUpper, L);
            next += BLOCKS_PER_DAY;
        }
        vm.rollFork(config.endBlock);
        FeeTracker.Snapshot memory last = tracker.takeSnapshot(config.pool, config.tickLower, config.tickUpper, L);

        // 5) Close the position at the final price; add back the idle-cash leftover so the
        //    finalAmount fields represent everything the LP walks away with.
        (uint256 positionEnd0, uint256 positionEnd1) =
            PositionSimulator.computeAmounts(last.sqrtPriceX96, config.tickLower, config.tickUpper, L);
        result.finalAmount0 = positionEnd0 + leftover0;
        result.finalAmount1 = positionEnd1 + leftover1;
        result.totalFees0 = last.cumulativeFee0;
        result.totalFees1 = last.cumulativeFee1;

        // 6) Price everything in USD at endBlock.
        (uint256 p0, uint256 p1) = _tokenPricesUsd1e18(pool);

        uint256 feesUsd = result.totalFees0 * p0 + result.totalFees1 * p1;
        uint256 hodlUsd = config.amount0 * p0 + config.amount1 * p1;
        int256 ilUsd = ILCalculator.impermanentLossUSD(
            config.amount0, config.amount1, result.finalAmount0, result.finalAmount1, p0, p1
        );

        result.feesUSD = feesUsd;
        result.hodlValueUSD = hodlUsd;
        result.ilUSD = ilUsd;
        result.netPnlUSD = ilUsd + int256(feesUsd);

        // 7) Days-in-range bookkeeping.
        uint256 snapCount = tracker.snapshotCount();
        for (uint256 i = 0; i < snapCount; i++) {
            if (tracker.snapshotAt(i).inRange) result.daysInRange++;
            else result.daysOutOfRange++;
        }

        // 8) APR (bps) annualized vs hodl value, based on net P&L. Integer-safe: we scale
        //    numerator up to 1e18 before dividing. 365 days/year × 10_000 bps/unit = 3_650_000.
        if (hodlUsd > 0 && snapCount > 1) {
            int256 hodlSigned = int256(hodlUsd);
            int256 periodDays = int256(snapCount - 1);
            // aprBps = netPnl / hodl * (365 / periodDays) * 10_000
            result.aprBps = (result.netPnlUSD * int256(365) * int256(10_000)) / (hodlSigned * periodDays);
        }

        // 9) Copy the snapshot array to memory for the return value.
        result.snapshots = new FeeTracker.Snapshot[](snapCount);
        for (uint256 i = 0; i < snapCount; i++) {
            result.snapshots[i] = tracker.snapshotAt(i);
        }
    }

    // ---------- pricing ----------

    /// @dev Returns (price0, price1) as USD (1e18-fixed) per **one base unit** of each token.
    ///      Example: USDC (6 dec) at $1 → 1e12. WETH at $3500 → 3500. Caller multiplies by raw
    ///      wei amounts, result is 1e18 USD.
    function _tokenPricesUsd1e18(IUniswapV3Pool pool) private view returns (uint256 price0, uint256 price1) {
        price0 = _priceTokenInUsdPerBaseUnit(pool.token0());
        price1 = _priceTokenInUsdPerBaseUnit(pool.token1());
    }

    function _priceTokenInUsdPerBaseUnit(address token) private view returns (uint256) {
        if (token == Pools.USDC || token == Pools.USDT) {
            // Both are 6-decimal pegged stables. Treat as exactly $1 — good enough for backtests.
            return 1e12;
        }
        if (token == Pools.WETH) {
            return priceOracle.getEthUsd() / 1e18;
        }
        if (token == Pools.WBTC) {
            // Route via WBTC/WETH 0.30%. token0=WBTC(8), token1=WETH(18).
            // WBTC/WETH price (WETH wei per WBTC sat) = sqrtPriceX96^2 / 2^192.
            // Then convert to USD via WETH price.
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(Pools.WBTC_ETH_030).slot0();
            uint256 wethPerSat1e18 = _sqrtPriceX96ToRatio1e18(sqrtPriceX96);
            uint256 wethUsdPerWei1e18 = priceOracle.getEthUsd() / 1e18;
            // wethPerSat * wethUsdPerWei = USD per sat in 1e36; scale back to 1e18.
            return (wethPerSat1e18 * wethUsdPerWei1e18) / 1e18;
        }
        revert("LPBacktest: unsupported token");
    }

    /// @dev Returns `sqrtPriceX96^2 / 2^192` expressed as 1e18 fixed-point.
    ///      Uses two `mulDiv` calls (512-bit intermediate) so it stays correct across the entire
    ///      `uint160` sqrtPriceX96 domain. A naive `sqrt * sqrt * 1e18` overflows `uint256` for
    ///      typical WBTC/WETH values (sqrtPriceX96 ≈ 4e34, squared ≈ 1.6e69, ×1e18 ≈ 1.6e87).
    function _sqrtPriceX96ToRatio1e18(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 ratioX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(ratioX96, 1e18, 1 << 96);
    }
}
