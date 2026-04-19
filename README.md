# lp-replay

> Replay any Uniswap V3 LP position on historical mainnet. See actual P&L.

A Foundry-based backtester for Uniswap V3 concentrated liquidity. Pick a
pool, a window, deposit amounts, and a tick range — `lp-replay` forks
mainnet across the window, simulates the position, tracks fees and
impermanent loss at daily cadence, and reports net P&L vs HODL.

No private keys. No real transactions. Runs inside `forge test` forks.

## Quick start

```bash
git clone --recurse-submodules <this-repo>
cd lp-replay
# If you cloned without --recurse-submodules:
git submodule update --init --recursive
cp .env.example .env   # set MAINNET_RPC_URL
forge test --match-path 'test/scenarios/*'
```

A minimal custom backtest:

```solidity
LPBacktest backtest = new LPBacktest();
LPBacktest.Result memory r = backtest.run(
    LPBacktest.Config({
        pool: Pools.ETH_USDC_005,
        startBlock: 19_800_000,
        endBlock: 20_200_000,
        amount0: 30_000e6,    // USDC (6 decimals)
        amount1: 10 ether,    // WETH
        tickLower: 193_870,
        tickUpper: 197_880
    })
);
// r.feesUSD, r.ilUSD, r.netPnlUSD, r.aprBps, r.snapshots[]
```

## Reference scenarios

All three replay blocks `19_800_000 → 20_200_000` (May 4 → Jun 29, 2024,
~56 days). Numbers below are actual `forge test` output, not estimates —
reproduce them yourself and they should match to the cent.

| Scenario | Range | Days in range | Fees | IL | Net P&L | APR |
|---|---:|---:|---:|---:|---:|---:|
| **Wide ETH/USDC** | ±2000 ticks | 52 / 57 | +$2,427 | −$522 | **+$1,905** | **19.5%** |
| **Narrow ETH/USDC** | ±500 ticks | 10 / 57 | +$2,167 | −$1,735 | **+$432** | **4.4%** |
| **Stable USDC/USDT** | ±10 ticks | 50 / 57 | +$32,261 | +$29 | **+$32,290** | **105%** |

Same window, same wide-deposit capital, **4× outcome gap purely from
range selection**. Narrow earned *less* absolute fees than wide (10 of
57 days in range) while taking 3× the IL. Stable is a separate regime —
structurally near-zero IL when both legs are pegged.

Side-by-side commentary in
[`docs/STRATEGY_COMPARISON.md`](docs/STRATEGY_COMPARISON.md).

## Result struct

```
feesUSD, ilUSD, netPnlUSD, hodlValueUSD    // the headline numbers
daysInRange, daysOutOfRange, aprBps         // diagnostics
snapshots[]                                 // per-day record for analysis
```

Fee attribution uses V3 whitepaper §6.3 with `feeGrowthGlobal`-delta
rather than naive `feeGrowthInside`-delta — robust to boundary tick
re-initialization. Details in
[`src/FeeTracker.sol`](src/FeeTracker.sol).

## IL math

```
IL_USD = (finalAmount0·p0_end + finalAmount1·p1_end)
       − (startAmount0·p0_end + startAmount1·p1_end)
```

Both legs valued at end-block prices, so directional moves cancel; what
remains is the V3 rebalancing penalty. Worked examples in
[`docs/IL_MATH.md`](docs/IL_MATH.md).

## Limitations

- **Daily snapshot cadence** under-resolves in/out-of-range transitions
  on tight ranges in volatile pools.
- **Stable prices hardcoded to $1.** USDC/USDT depegs not modeled.
- **No gas, no MEV, no rebalancing.** Position has constant `L` over
  `[tickLower, tickUpper]` for the whole window.

`src/libraries/` contains 0.8.x ports of Uniswap's 0.7.6 V3 math libs
(`TickMath`, `FullMath`, `LiquidityAmounts`, `FixedPoint96/128`) with
`unchecked` wrappers; SPDX headers preserve upstream licensing
(`GPL-2.0-or-later` for TickMath/LiquidityAmounts, `MIT` for the rest).

## License

MIT. See [LICENSE](LICENSE).