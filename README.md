# bots

MetaTrader 5 Expert Advisors (EAs).

| File | EA | Timeframe | Concept |
|---|---|---|---|
| [AsiaRangeBreakout.mq5](AsiaRangeBreakout.mq5) | Asia Range Breakout | Any (uses M1 data for the range) | Stop orders at the Asia session high/low |
| [CRT.mq5](CRT.mq5) | CRT OTE | M15 / H1 / H4 | Candle Range Theory sweep of the higher-timeframe candle + OTE limit entries |
| [QT.mt5](QT.mt5) | Quarterly Theory CRT | M15 | CRT sweep of the previous 6-hour session high/low |

Folders:

- `sets/` – saved `.set` input files (see [naming of set files](tests/README.md#naming-of-set-files))
- `tests/` – backtest / optimization reports, test log and the [test procedure](tests/README.md)

## Installation

1. Copy the EA source into `<MT5 data folder>/MQL5/Experts/`.
   `QT.mt5` must be saved as `QT.mq5`, otherwise MetaEditor will not compile it.
2. Open it in MetaEditor and compile (F7).
3. Attach the EA to a chart of the intended timeframe and enable Algo Trading.

Every EA only manages orders and positions with its own magic number on the chart symbol, so several EAs can run in parallel as long as the magic numbers differ.

---

## Asia Range Breakout

[AsiaRangeBreakout.mq5](AsiaRangeBreakout.mq5)

**Logic**

1. After the Asia session ends, the session high and low are calculated from M1 data.
2. A buy stop is placed at the Asia high and a sell stop at the Asia low (only if price is not already beyond the level).
3. SL is the opposite side of the range, TP is `TP_RR` × range.
4. Optional one-cancels-other: once one stop is filled, the other one is deleted.
5. Unfilled stop orders are deleted at the cancel time.
6. One setup per day; the EA detects an existing setup after a restart.

**Inputs**

| Group | Input | Description |
|---|---|---|
| Asia Session (server time) | `AsiaStartHour` / `AsiaStartMinute` | Session start |
| | `AsiaEndHour` / `AsiaEndMinute` | Session end – orders are placed after this time |
| | `CancelHour` / `CancelMinute` | Delete unfilled stop orders (must be after session end) |
| Risk | `RiskPercent` | Risk per trade in % of balance |
| | `TP_RR` | Take profit as multiple of risk |
| Filters | `UseEMAFilter` / `EMAPeriod` | Longs only if the previous daily close is above the daily EMA, shorts only below |
| | `OneCancelsOther` | Delete the opposite stop order once one is filled |
| Break-Even | `UseBreakEven` / `BreakEvenAtR` | Move SL to entry once price moved `BreakEvenAtR` × risk |
| Market Close | `CloseTradesBeforeClose` / `MinutesBeforeClose` | Close all open trades shortly before the symbol's trade session ends |
| Trade Settings | `MagicNumber`, `TradeComment` | EA identity |

---

## CRT OTE

[CRT.mq5](CRT.mq5)

**Logic**

The higher timeframe (HTF) is chosen from the chart timeframe:

| Chart | HTF levels |
|---|---|
| M15 | H4 |
| H1 | Daily |
| H4 | Weekly |

1. Track the high and low of the previous completed HTF candle.
2. **Bearish:** a closed bar sweeps the HTF high, then within `MaxConfirmBars` a bar closes below the sweep candle's low → sell.
   **Bullish:** mirror image on the HTF low → buy.
3. Entries on confirmation:
   - #1 market order
   - #2–#4 limit orders at the 0.618 / 0.705 / 0.786 Fibonacci retracement of the sweep extreme → confirmation low/high
4. Common SL at the sweep extreme (+ buffer); each entry has its own risk % and TP R:R.
5. While price extends further without reaching 0.618, the Fibonacci levels and pending limits are moved. Once 0.618 is reached the levels are frozen.
6. A close beyond the SL invalidates the setup and cancels the remaining limits.
7. One setup per direction per HTF period.

**Inputs**

| Group | Input | Description |
|---|---|---|
| Entry Settings | `MaxConfirmBars` | Max bars after the sweep for confirmation |
| | `SlBufferPoints` | SL buffer beyond the sweep (points) |
| Entry Toggles | `UseMarketEntry`, `UseLimit618`, `UseLimit705`, `UseLimit786` | Enable the individual entries |
| Order Block Filter | `RequireOBForLimits`, `OBLookbackBars`, `OBTolerancePoints` | Only place a limit if an order block to the left covers the price |
| Fair Value Gap Filter | `RequireFVGForLimits`, `FVGLookbackBars`, `FVGTolerancePoints` | Only place a limit if an FVG to the left covers the price |
| Risk Settings | `RiskPct_Market`, `RiskPct_618`, `RiskPct_705`, `RiskPct_786` | Risk % per entry |
| | `TP_R_Market`, `TP_R_618`, `TP_R_705`, `TP_R_786` | TP R:R per entry |
| Break-Even | `UseBreakEven` / `BreakEvenAtR` | Move SL to entry after trigger R |
| Partial Close | `UsePartialClose` / `PartialCloseAtR` | Close 50 % of the position after trigger R |
| Pending Limit Cut-off (server time) | `CancelBeforeDailyClose`, `DailyCancelHour`, `DailyCancelMinute` | Delete pending limits before the daily close |
| | `CancelBeforeWeekend`, `FridayCancelHour`, `FridayCancelMinute` | Delete pending limits before the weekend |
| Direction Filter | `AllowLongs`, `AllowShorts` | Enable directions |
| | `UseDailyEMAFilter` / `DailyEMAPeriod` | Longs only above / shorts only below the daily EMA |
| Trade Settings | `MagicNumber`, `SlippagePoints`, `TradeComment` | EA identity / execution |

---

## Quarterly Theory CRT

[QT.mt5](QT.mt5) – ported from the "Quarterly Theory CRT" Pine Script indicator.

**Logic** (evaluated on closed M15 bars)

The day is split into four 6-hour sessions (in the target timezone, see `InpSessionGMTOffset`):

| Session | Time |
|---|---|
| Asian | 00:00 – 06:00 |
| London | 06:00 – 12:00 |
| New York | 12:00 – 18:00 |
| Fourth | 18:00 – 00:00 |

1. Track the previous session's high and low.
2. **Bearish:** sweep of the previous session high, then within `InpMaxConfirmBars` a candle closes below the sweep candle's low → sell.
   **Bullish:** sweep of the previous session low, then a candle closes above the sweep candle's high → buy.
3. Entries: market order and/or limits at 0.618 / 0.705 / 0.786 of the session extreme → confirmation candle range. Unfilled limits are cancelled at the next session roll-over.
4. SL beyond the current session extreme (+ buffer), TP at `InpTakeProfitRR` × risk from each entry.
5. One trade per direction per session.

**Inputs**

| Group | Input | Description |
|---|---|---|
| Risk Management | `InpRiskPercent` | Risk per trade in % of balance |
| | `InpSLBufferPoints` | Extra SL buffer beyond the session extreme (points) |
| | `InpTakeProfitRR` | Take profit as R multiple |
| Session Settings | `InpSessionGMTOffset` | Hours added to broker time to get the session timezone |
| | `InpTradeAsian`, `InpTradeLondon`, `InpTradeNewYork`, `InpTradeFourth` | Enable new entries per session |
| Entry Settings | `InpMaxConfirmBars` | Max bars after the sweep for confirmation |
| | `InpUseMarketEntry`, `InpUseLimit618`, `InpUseLimit705`, `InpUseLimit786` | Enable the individual entries |
| | `InpLimitRequireOB`, `InpLimitRequireFVG` | Only place limits if an order block / FVG formed in the sweep leg |
| Market Close | `InpCancelLimitsBeforeClose` / `InpMinutesBeforeClose` | Delete pending limits shortly before the symbol's trade session ends |
| Break-Even | `InpUseBreakEven` / `InpBreakEvenAtR` | Move SL to entry after trigger R |
| Direction Filter | `InpTradeShorts`, `InpTradeLongs` | Enable directions |
| | `InpUseDailyEMAFilter` / `InpDailyEMAPeriod` | Longs only above / shorts only below the daily EMA |
| EA Identity | `InpMagicNumber`, `InpMaxSlippage` | EA identity / execution |
