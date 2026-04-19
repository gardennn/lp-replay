# lp-replay

> Replay any Uniswap V3 LP position on historical mainnet. See actual P&L.

A Foundry-based backtester for Uniswap V3 concentrated liquidity. Pick a pool, a
window, deposit amounts, and a tick range — `lp-replay` forks mainnet across the
window, simulates opening the position, tracks fees and impermanent loss
block-by-block at daily cadence, and reports net P&L versus a HODL benchmark.

No private keys. No real transactions. Everything runs locally inside `forge test`
forks.

## What it does

For each backtest you get back a `Result` containing:

- `finalAmount0`, `finalAmount1` — what the position would redeem to at the end
  block, **including** any idle-cash leftover from the binding-side deposit math.
- `totalFees0`, `totalFees1`, `feesUSD` — fees accrued to the virtual position over
  the window, attributed only during snapshots when the position was in range.
- `ilUSD` — impermanent loss versus HODL, signed (negative = LP underperformed).
- `netPnlUSD` — `ilUSD + feesUSD`, the bottom line.
- `hodlValueUSD` — what the same starting tokens would be worth at the end-block
  oracle price.
- `daysInRange` / `daysOutOfRange` — how often the price was inside `[tickLower, tickUpper]`.
- `aprBps` — net P&L annualized vs HODL, in basis points.
- `snapshots[]` — full per-day record of price, in-range flag, fee-growth state, and
  cumulative fees, for further analysis.

See `src/LPBacktest.sol` for the orchestrator and `src/FeeTracker.sol` for the
fee-attribution math (V3 §6.3 with the modular-arithmetic robustness notes).

## Quick start

```bash
git clone --recurse-submodules <this-repo>
cd lp-replay
cp .env.example .env   # then edit .env with your Alchemy/Infura mainnet RPC
forge build
forge test
```

The forking tests need `MAINNET_RPC_URL` set (in `.env` or your shell).
`forge test` runs everything; `forge test --match-path 'test/scenarios/*'` runs
just the three reference scenarios.

A minimal test of your own:

```solidity
import {LPBacktest} from "src/LPBacktest.sol";
import {Pools} from "src/Pools.sol";

LPBacktest backtest = new LPBacktest();
LPBacktest.Result memory r = backtest.run(
    LPBacktest.Config({
        pool: Pools.ETH_USDC_005,
        startBlock: 19_800_000,
        endBlock: 20_200_000,
        amount0: 30_000e6,   // USDC (6 decimals)
        amount1: 10 ether,   // WETH
        tickLower: 193_870,  // tick-spacing-aligned
        tickUpper: 197_880
    })
);
```

## Example output (T5.1 — ETH/USDC wide, 56 days)

```
=== T5.1 wide-range ETH/USDC (HALF_WIDTH=2000) ===
entry tick:               195876
range tick lower:         193870
range tick upper:         197880
snapshots:                57
days in range:            52
days out of range:        5
hodl USD (1e18):          63750000000000000000000   ($63,750)
fees USD (1e18):          2426784213165679295000    ($2,426.78)
IL USD   (1e18, signed):  -521914455528140755500    (-$521.91)
net P&L  (1e18, signed):  1904869757637538539500    (+$1,904.87)
APR bps (signed):         1947                       (19.47%)
```

## Reference scenarios

Three short scenarios live in `test/scenarios/`:

- **`ETH_USDC_Wide_May2024.t.sol`** — 30k USDC + 10 WETH, ±2000 ticks, 56 days.
- **`ETH_USDC_Narrow_May2024.t.sol`** — same deposit, ±500 ticks. Demonstrates the
  classic "narrow range earns more per in-range day, but spends most days out of
  range" failure mode.
- **`USDC_USDT_Stable.t.sol`** — 100k of each stable in the 0.01% pool, ±10 ticks.
  Yields the strongest fees-to-IL ratio in the dataset.

Side-by-side commentary lives in [`docs/STRATEGY_COMPARISON.md`](docs/STRATEGY_COMPARISON.md).

## IL math summary

Impermanent loss in this backtester is a **dollar quantity at end-block**:

```
IL_USD = (finalAmount0 · price0_end + finalAmount1 · price1_end)
       − (startAmount0 · price0_end + startAmount1 · price1_end)
```

Both legs are valued at the same end-of-window prices, so directional moves of the
underlying assets cancel — what's left is the rebalancing penalty intrinsic to a
V3 position. Fees are tracked separately and added on top to produce `netPnlUSD`.

Worked examples and the closed-form derivation are in
[`docs/IL_MATH.md`](docs/IL_MATH.md).

## Repo layout

```
src/
├── LPBacktest.sol           # main entry — run(Config) returns Result
├── PositionSimulator.sol    # liquidity ↔ token amount math
├── FeeTracker.sol           # per-snapshot fee accrual
├── ILCalculator.sol         # IL vs HODL
├── PriceOracle.sol          # ETH/USD from the ETH/USDC 0.05% pool
├── Pools.sol                # hardcoded mainnet token + pool addresses
└── libraries/               # 0.8.x ports of FullMath, TickMath, LiquidityAmounts
test/
├── *.t.sol                  # unit + fork tests for each module
└── scenarios/               # reference end-to-end backtests
docs/
├── IL_MATH.md
└── STRATEGY_COMPARISON.md
.specs/                      # constitution, spec, plan, task list
```

## Library ports

`src/libraries/` contains direct ports of Uniswap V3 math libraries — `TickMath`,
`FullMath`, `FixedPoint96`, `FixedPoint128` from
[`v3-core/contracts/libraries`](https://github.com/Uniswap/v3-core/tree/main/contracts/libraries),
plus `LiquidityAmounts` from
[`v3-periphery/contracts/libraries`](https://github.com/Uniswap/v3-periphery/tree/main/contracts/libraries).
Upstream targets Solidity 0.7.6 and relies on silent overflow wrap; we re-host the files
under `pragma ^0.8.24` with the relevant arithmetic wrapped in `unchecked` blocks to
preserve the original semantics under 0.8.x's checked math. Each file's SPDX header carries
the upstream license unchanged — `GPL-2.0-or-later` for `TickMath` and `LiquidityAmounts`,
`MIT` for the three FixedPoint/FullMath helpers.

## Limitations

- **Daily snapshot cadence** under-resolves in/out-of-range transitions on tight
  ranges in volatile pools. `FeeTracker` documents the exact in-range coverage
  rule it uses.
- **Idle leftover earns no fees.** The backtester correctly *accounts* for the
  leftover (so it doesn't appear as phantom IL), but a real LP would deploy it
  somewhere — that opportunity cost is not modeled.
- **Stable prices are hardcoded to $1.** USDC/USDT depegs are not modeled. Real
  depeg events would dominate any LP P&L in those pools and aren't reflected here.
- **No gas, no MEV.** Position open/close is free, and we never simulate JIT
  liquidity or sandwich exposure.
- **No rebalancing.** The position has constant `L` over `[tickLower, tickUpper]`
  for the whole window. Auto-rebalance strategies are out of scope for v1.

## License

MIT. See [LICENSE](LICENSE).

[hm]: docs/HISTORICAL_MOMENTS.md
