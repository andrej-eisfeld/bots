# Test procedure

The goal is to find parameters that work on data they were **not** optimized on. Follow the steps in order and do not go back to an earlier step with knowledge from a later one.

## 1. Tester settings

| Setting | Value |
|---|---|
| Modelling | **Every tick based on real ticks** (break-even, same-bar SL/TP and stop entries are not reliable on OHLC) |
| Data | Broker you will trade live (session times are server time) |
| Spread / commission | Realistic values of the live account |
| Deposit / leverage | Same as the live account |
| Risk % | Fixed – never optimized |

## 2. Split the data before running anything

| Segment | Example | Purpose |
|---|---|---|
| In-sample (IS) | 2019-01-01 – 2023-12-31 | Optimization |
| Out-of-sample (OOS) | 2024-01-01 – 2025-06-30 | One-time validation |
| Holdout / forward | 2025-07-01 – today, then demo | Final confirmation |

- The IS period must contain at least ~200 trades.
- The Strategy Tester **Forward** option (1/2, 1/3, 1/4 or custom date) can be used to run IS and OOS in one optimization.

## 3. Optimize on in-sample

- Optimize only 3–5 parameters with coarse steps. Candidates:
  - **AsiaRangeBreakout:** `AsiaEndHour`, `CancelHour`, `TP_RR`, `UseEMAFilter`, `UseBreakEven`
  - **CRT:** `MaxConfirmBars`, `SlBufferPoints`, entry toggles, `TP_R_*`, `UseBreakEven`
  - **QT:** `InpTakeProfitRR`, `InpSLBufferPoints`, `InpMaxConfirmBars`, session toggles, market vs. limit entries
- Never optimize magic number, slippage or risk %.
- Criterion: Profit Factor, Recovery Factor, Sharpe Ratio or Complex Criterion – **not** Balance max (compounding inflates it).
- Ignore passes with too few trades.

## 4. Select a robust parameter set

- Use the 2D/3D optimization chart and pick a set from a **plateau** where neighbouring values also perform well.
- Do not pick an isolated best pass – it is almost certainly curve-fitted.

## 5. Out-of-sample backtest (once)

- Run the selected set unchanged on the OOS period.
- Pass criteria (guideline): Profit Factor > 1.2, drawdown comparable to IS, equity curve consistent with IS.
- If it fails, **do not** tweak parameters until OOS passes – that turns OOS into in-sample. Go back to step 3 with a different approach or drop the strategy.

## 6. Robustness checks

- **Walk-forward:** repeat steps 3–5 on rolling windows (e.g. 2 years IS / 6 months OOS, shifted by 6 months). Results should hold in most windows.
- **Stress test:** double the spread, add slippage, shift session times by ±1 hour.
- **Other markets:** run the same set on related symbols.
- **Monte Carlo:** shuffle the trade sequence of the exported trades to estimate a realistic worst-case drawdown.

## 7. Forward test

Run the set 1–3 months on a demo or small live account and compare fills, spread and trade frequency with a backtest of the same period.

## Naming of set files

Store every selected set in [`../sets/`](../sets/):

```
<EA>_<Symbol>_<Timeframe>_IS<from>-<to>.set
e.g. AsiaRangeBreakout_EURUSD_M15_IS2019-2023.set
```

Store the matching tester reports in this folder and record each run in a test log with: EA, symbol, timeframe, IS/OOS dates, set file, Profit Factor, max drawdown, number of trades and pass/fail. This way it is always clear which data a set has already "seen".
