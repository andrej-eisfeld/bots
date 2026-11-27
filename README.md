# bots

MetaTrader 5 Expert Advisors (EAs).

| File | EA | Timeframe | Concept |
|---|---|---|---|
| [AsiaRangeBreakout.mq5](AsiaRangeBreakout.mq5) | Asia Range Breakout | Any (uses M1 data for the range) | Stop orders at the Asia session high/low |
| [CRT.mq5](CRT.mq5) | CRT OTE | M15 / H1 / H4 | Candle Range Theory sweep of the higher-timeframe candle + OTE limit entries |
| [QT.mt5](QT.mt5) | Quarterly Theory CRT | M15 | CRT sweep of the previous 6-hour session high/low |
| [DailyKeyZones.mq5](DailyKeyZones.mq5) | Daily EMA Zone Engulfing | Any lower TF (zones from D1) | Engulfing candle inside a daily order block / FVG, in the direction of the daily EMA |
| [TDM.mq5](TDM.mq5) | TD Sequential (XAUUSD) | Any | Entry on a completed TD Sequential buy or sell setup |
| [TT.mq5](TT.mq5) | Turtle Trader | D1 (original rules) | Donchian channel breakout, Turtle System 1 + 2 with N-based sizing |

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

---

## Daily EMA Zone Engulfing

[DailyKeyZones.mq5](DailyKeyZones.mq5)

**Logic** (evaluated once per new bar of the signal timeframe)

1. **Trend:** the signal candle closes above (long) / below (short) the `InpEMAPeriod` EMA of the higher timeframe `InpHTF`.
2. **Zone:** the two-candle pattern overlaps a higher-timeframe zone scanned over the last `InpZoneLookback` completed HTF bars:
   - Bullish order block: bearish candle followed by a candle closing above its high (bearish OB mirrored).
   - Bullish FVG: gap between the high of candle 1 and the low of candle 3 (bearish FVG mirrored).
   - Optionally, zones already broken by an HTF close are ignored.
3. **Trigger:** engulfing candle on the signal timeframe, optionally with tick volume above the average of the previous `InpVolumePeriod` bars.
4. Market entry. SL beyond the engulfed candle (or both candles), an ATR distance, or candle + ATR buffer. TP at `InpRiskReward` × risk.
5. Optional break-even with lock-in offset; optionally only one open position at a time.

**Inputs**

| Group | Input | Description |
|---|---|---|
| Trend filter | `InpHTF` | Higher timeframe for EMA and zones |
| | `InpEMAPeriod` | EMA period |
| Daily zones | `InpZoneMode` | Order blocks and FVGs / OB only / FVG only |
| | `InpZoneLookback` | HTF bars to scan for zones |
| | `InpRemoveMitigated` | Ignore zones broken by an HTF close |
| Entry | `InpSignalTF` | Engulfing (signal) timeframe |
| | `InpEnableBuy`, `InpEnableSell` | Enable directions |
| | `InpOnePosition` | Only one open position at a time |
| Volume filter | `InpUseVolumeFilter` / `InpVolumePeriod` | Require above-average tick volume on the engulfing candle |
| Stop loss / Take profit | `InpSLMode` | Beyond engulfed candle / ATR distance / candle + ATR buffer |
| | `InpSLUsePattern` | Use the extreme of both candles instead of only the engulfed one |
| | `InpSLBufferPips` | Extra buffer beyond the candle (pips) |
| | `InpATRPeriod` / `InpATRMult` | ATR settings (signal timeframe) |
| | `InpRiskReward` | TP as R multiple |
| Breakeven | `InpUseBreakeven`, `InpBETriggerRR`, `InpBEOffsetPips` | Move SL to entry + offset after trigger R |
| Money management | `InpLotMode` | Fixed lots / risk % of balance |
| | `InpLots`, `InpRiskPercent` | Fixed lot size / risk per trade |
| | `InpMagic` | Magic number |

---

## TD Sequential (XAUUSD)

[TDM.mq5](TDM.mq5) – designed for XAUUSD.

**Logic** (evaluated once per closed bar of the chart timeframe)

1. **Setup:** a TD Sequential setup completes on the last closed bar – exactly 9 consecutive bars with `close < close[4]` (buy) or `close > close[4]` (sell). A 10th bar would mean the setup already fired earlier.
2. Optional filter: buy only if the last daily close is above the daily EMA, sell only if below.
3. Market order. Buy: TP at the high of the current month; sell: TP at the low of the current month (`PERIOD_MN1`, shift 0). SL at the same distance on the other side of the entry (1:1). Lot size risks `InpRiskPercent` of balance.
4. Optional risk reduction: when a new position opens, other positions of this EA that are in drawdown get their TP moved to their entry price.

Multiple positions can be open at the same time – every completed setup opens a new trade.

**Inputs**

| Group | Input | Description |
|---|---|---|
| Trade Settings | `InpRiskPercent` | Risk per trade in % of balance |
| | `InpTradeLongs`, `InpTradeShorts` | Trade buy / sell setups |
| Daily EMA Filter | `InpUseDailyEMAFilter` / `InpDailyEMAPeriod` | Buy only above / sell only below the daily EMA (last daily close) |
| Risk Reduction | `InpTPAtEntryOnNew` | On a new position, move the TP of other losing positions to entry |
| EA Identity | `InpMagicNumber` | Magic number |

---

## Turtle Trader

[TT.mq5](TT.mq5) – based on the original Turtle rules and the "Turtle Trade Channels Indicator" (TuTCI).

**Logic** (evaluated once per closed bar of the working timeframe, only while the symbol's session is open)

| System | Entry | Exit |
|---|---|---|
| S1 (fast) | 20-bar breakout | 10-bar opposite breakout |
| S2 (fail-safe) | 55-bar breakout | 20-bar opposite breakout |

1. **Entry:** when flat, go long on a break above the highest high (short below the lowest low) of the previous entry-period bars. S2 is preferred if both trigger.
2. **S1 filter:** an S1 breakout is only taken if the previous S1 signal would have been a loss. This is tracked with a simulated ("phantom") S1 trade, so it works whether or not the signal was actually traded. S2 breakouts are always taken.
3. **Exit:** close on a break of the opposite exit channel (S1 or S2 length, taken from the position comment).
4. **Stops:** N = ATR. Optional hard stop at `InpStopN` × N from the entry.
5. **Sizing:** one Unit risks `InpRiskPerN_Percent` of equity per 1N move (or a fixed lot), capped at `InpMaxLot`.
6. **Pyramiding (optional):** add a Unit every `InpAddStepN` × N in favour, up to `InpMaxUnits`, and trail all stops to `InpStopN` × N from the last close.
7. Exits are always managed. New entries and pyramiding can be blocked on Mondays and Fridays (both blocked by default) and when the spread is too high.

**Inputs**

| Group | Input | Description |
|---|---|---|
| General | `InpTimeframe` | Working timeframe (Turtles used D1) |
| System 1 | `InpUseS1`, `InpEntryS1`, `InpExitS1` | Enable S1, entry / exit channel lengths |
| | `InpUseS1Filter` | Skip S1 entries if the last S1 signal was a win |
| System 2 | `InpUseS2`, `InpEntryS2`, `InpExitS2` | Enable S2, entry / exit channel lengths |
| Volatility / Stops | `InpATRPeriod` | ATR period (N) |
| | `InpStopN` | Initial stop distance in N |
| | `InpUseHardStop` | Attach the stop-loss to the order |
| Position Sizing | `InpUseRiskSizing`, `InpRiskPerN_Percent` | Volatility sizing: % of equity per 1N |
| | `InpFixedLot`, `InpMaxLot` | Fixed lot (sizing off) and hard lot cap |
| Pyramiding | `InpUsePyramiding`, `InpMaxUnits`, `InpAddStepN` | Add Units in favour of the trade |
| Trade Control | `InpMagic`, `InpSlippagePoints`, `InpTradeComment` | EA identity / execution |
| | `InpMaxSpreadPoints` | Max spread for entries (0 = ignore) |
| | `InpTradeMonday`, `InpTradeFriday` | Allow new entries on Monday / Friday (server time) |
