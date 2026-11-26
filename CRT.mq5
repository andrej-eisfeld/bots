//+------------------------------------------------------------------+
//|  CRT OTE EA                                                      |
//|  Candle Range Theory – OTE Entry EA                              |
//|                                                                  |
//|  Timeframe auto-detection:                                       |
//|    1H chart  → uses Daily HTF levels                             |
//|    4H chart  → uses Weekly HTF levels                            |
//|                                                                  |
//|  Entry structure (per signal):                                   |
//    #1  Market order on signal bar close  (toggle: UseMarketEntry)|
//|    #2  Limit at 0.618 Fib               (toggle: UseLimit618)   |
//|    #3  Limit at 0.705 Fib               (toggle: UseLimit705)   |
//|    #4  Limit at 0.786 Fib               (toggle: UseLimit786)   |
//|  Common SL: sweep extreme (+/- buffer)                           |
//+------------------------------------------------------------------+
#property copyright "CRT OTE EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//-------------------------------------------------------------------
// INPUTS
//-------------------------------------------------------------------
input group "=== Entry Settings ==="
input int    MaxConfirmBars  = 6;      // Max bars after sweep for confirmation
input double SlBufferPoints  = 0.0;    // SL buffer beyond sweep (points)

input group "=== Entry Toggles ==="
input bool   UseMarketEntry  = true;   // Enable market entry (#1)
input bool   UseLimit618     = true;   // Enable 0.618 limit entry (#2)
input bool   UseLimit705     = false;  // Enable 0.705 limit entry (#3)
input bool   UseLimit786     = true;   // Enable 0.786 limit entry (#4)

input group "=== Order Block Filter ==="
input bool   RequireOBForLimits = false; // Place limits only if an order block to the left covers the price
input int    OBLookbackBars     = 50;    // Bars to look left for order blocks
input double OBTolerancePoints  = 0.0;   // Allowed distance of limit price outside the OB (points)

input group "=== Fair Value Gap Filter ==="
input bool   RequireFVGForLimits = false; // Place limits only if an FVG to the left covers the price
input int    FVGLookbackBars     = 50;    // Bars to look left for FVGs
input double FVGTolerancePoints  = 0.0;   // Allowed distance of limit price outside the FVG (points)

input group "=== Risk Settings ==="
input double RiskPct_Market  = 0.10;   // Risk % for market entry (#1)
input double RiskPct_618     = 0.10;   // Risk % for 0.618 limit entry (#2)
input double RiskPct_705     = 0.10;   // Risk % for 0.705 limit entry (#3)
input double RiskPct_786     = 0.10;   // Risk % for 0.786 limit entry (#4)
// TP multiples
input double TP_R_Market     = 1.0;    // TP R:R for market entry
input double TP_R_618        = 1.0;    // TP R:R for 0.618 limit entry
input double TP_R_705        = 1.0;    // TP R:R for 0.705 limit entry
input double TP_R_786        = 1.0;    // TP R:R for 0.786 limit entry

input group "=== Break-Even ==="
input bool   UseBreakEven    = false;  // Move SL to entry after reaching trigger R
input double BreakEvenAtR    = 1.0;    // R multiple that triggers break-even

input group "=== Partial Close ==="
input bool   UsePartialClose = false;  // Close 50% of the position after reaching trigger R
input double PartialCloseAtR = 1.0;    // R multiple that triggers the 50% partial close

input group "=== Pending Limit Cut-off (server time) ==="
input bool   CancelBeforeDailyClose = false; // Delete pending limits before daily market close
input int    DailyCancelHour        = 23;    // Daily cut-off hour
input int    DailyCancelMinute      = 45;    // Daily cut-off minute
input bool   CancelBeforeWeekend    = false; // Delete pending limits before the weekend (Friday)
input int    FridayCancelHour       = 23;    // Friday cut-off hour
input int    FridayCancelMinute     = 0;     // Friday cut-off minute

input group "=== Direction Filter ==="
input bool   AllowLongs      = true;   // Allow long trades
input bool   AllowShorts     = true;   // Allow short trades
input bool   UseDailyEMAFilter = false; // Longs only above / shorts only below the daily EMA
input int    DailyEMAPeriod    = 50;    // Daily EMA period

input group "=== Trade Settings ==="
input int    MagicNumber     = 202501; // Magic number
input int    SlippagePoints  = 10;     // Slippage for market orders
input string TradeComment    = "my_crt_strategy";

//-------------------------------------------------------------------
// GLOBALS
//-------------------------------------------------------------------
CTrade         Trade;
CPositionInfo  PosInfo;
COrderInfo     OrdInfo;

// Timeframe context
ENUM_TIMEFRAMES CurrentTF;
ENUM_TIMEFRAMES HtfTF;
string          ModeLabel;

// HTF high/low (previous completed HTF candle)
double HtfHigh, HtfLow;

// Period tracking
double PeriodHigh, PeriodLow;
bool   PeriodTouchedBelowHtfH;
bool   PeriodTouchedAboveHtfL;
datetime LastPeriodTime;

// ── Bearish CRT state machine ──
//  0=scanning 1=swept 2=confirmed(waiting for limit fills) 3=0.618 reached(fibs frozen) 4=SL hit
int    BState;
double BSweepHigh;
double BSweepClose;   // low of sweep candle
int    BSweepBar;
int    BConfirmBar;
double BShort618, BShort705, BShort786;
double BSL;
bool   BPeriodDone;

// ── Bullish CRT state machine ──
int    LState;
double LSweepLow;
double LSweepClose;   // high of sweep candle
int    LSweepBar;
int    LConfirmBar;
double LLong618, LLong705, LLong786;
double LSL;
bool   LPeriodDone;

// Limit order tickets (0 = not placed / already filled / cancelled)
ulong  BLimitTicket618, BLimitTicket705, BLimitTicket786;
ulong  LLimitTicket618, LLimitTicket705, LLimitTicket786;

int    DailyEMAHandle = INVALID_HANDLE;

//-------------------------------------------------------------------
// HELPERS
//-------------------------------------------------------------------
bool IsSupportedTF()
{
   return (Period() == PERIOD_M15 || Period() == PERIOD_H1 || Period() == PERIOD_H4);
}

//--- Lot size from risk %
double CalcLots(double riskPct, double slPoints)
{
   if(slPoints <= 0) return 0;
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * riskPct / 100.0;
   double tickValue      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickValue <= 0 || tickSize <= 0) return minLot;

   double lossPerLot = (slPoints * _Point / tickSize) * tickValue;
   double lots = riskAmount / lossPerLot;
   lots = MathFloor(lots / lotStep + 1e-8) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return lots;
}

//--- Cancel a pending order by ticket
void CancelOrder(ulong &ticket)
{
   if(ticket == 0) return;
   if(Trade.OrderDelete(ticket))
      ticket = 0;
   else
      ticket = 0; // clear anyway to avoid repeated attempts
}

//--- Check if a pending order with this ticket still exists
bool OrderExists(ulong ticket)
{
   if(ticket == 0) return false;
   for(int i = OrdersTotal()-1; i>=0;i--)
   {
      ulong t = OrderGetTicket(i);
      if(t==ticket && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//--- Cancel all bear limits
void CancelBearLimits()
{
   CancelOrder(BLimitTicket618);
   CancelOrder(BLimitTicket705);
   CancelOrder(BLimitTicket786);
}

//--- Cancel all bull limits
void CancelBullLimits()
{
   CancelOrder(LLimitTicket618);
   CancelOrder(LLimitTicket705);
   CancelOrder(LLimitTicket786);
}

//--- Reset bearish state
void ResetBear()
{
   CancelBearLimits();
   BState      = 0;
   BSweepHigh  = 0;
   BSweepClose = 0;
   BSweepBar   = -1;
   BConfirmBar = -1;
   BShort618   = 0;
   BShort705   = 0;
   BShort786   = 0;
   BSL         = 0;
   BPeriodDone = false;
}

//--- Reset bullish state
void ResetBull()
{
   CancelBullLimits();
   LState      = 0;
   LSweepLow   = 0;
   LSweepClose = 0;
   LSweepBar   = -1;
   LConfirmBar = -1;
   LLong618    = 0;
   LLong705    = 0;
   LLong786    = 0;
   LSL         = 0;
   LPeriodDone = false;
}

//-------------------------------------------------------------------
// FETCH HTF HIGH / LOW  (previous completed HTF candle)
//-------------------------------------------------------------------
void FetchHtfLevels()
{
   HtfHigh = iHigh(_Symbol, HtfTF, 1);
   HtfLow  = iLow (_Symbol, HtfTF, 1);
}

//--- Uses the last closed daily candle so the bias doesn't flip intraday
bool DailyEMAAllows(bool isBuy)
{
   if(!UseDailyEMAFilter) return true;
   double ema[1];
   if(CopyBuffer(DailyEMAHandle, 0, 1, 1, ema) < 1) return false;
   double close = iClose(_Symbol, PERIOD_D1, 1);
   if(close == 0) return false;
   return isBuy ? close > ema[0] : close < ema[0];
}

//-------------------------------------------------------------------
// PLACE MARKET ORDER
//-------------------------------------------------------------------
void PlaceMarket(bool isBuy, double sl, double tp, double riskPct, string comment)
{
   double slPoints = MathAbs(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - sl) / _Point;
   if(!isBuy) slPoints = MathAbs(sl - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   double lots = CalcLots(riskPct, slPoints);
   if(lots <= 0) return;

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePoints);

   if(isBuy)
      Trade.Buy(lots, _Symbol, 0, sl, tp, comment);
   else
      Trade.Sell(lots, _Symbol, 0, sl, tp, comment);
}

//--- True if an order block to the left, not yet closed through, covers price
bool HasOrderBlockAt(bool isBuy, double price)
{
   if(!RequireOBForLimits) return true;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = OBLookbackBars;
   if(CopyRates(_Symbol, CurrentTF, 0, n + 1, r) < n + 1) return false;

   double tol      = OBTolerancePoints * _Point;
   double minClose = DBL_MAX, maxClose = -DBL_MAX; // closes of bars newer than s

   for(int s = 1; s <= n; s++)
   {
      if(s >= 2)
      {
         bool ob = isBuy ? (r[s].close < r[s].open && r[s-1].close > r[s].high && minClose >= r[s].low)
                         : (r[s].close > r[s].open && r[s-1].close < r[s].low  && maxClose <= r[s].high);
         if(ob && price >= r[s].low - tol && price <= r[s].high + tol)
            return true;
      }
      minClose = MathMin(minClose, r[s].close);
      maxClose = MathMax(maxClose, r[s].close);
   }
   return false;
}

//--- True if a fair value gap to the left, not yet closed through, covers price
bool HasFVGAt(bool isBuy, double price)
{
   if(!RequireFVGForLimits) return true;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = FVGLookbackBars;
   if(CopyRates(_Symbol, CurrentTF, 0, n + 3, r) < n + 3) return false;

   double tol      = FVGTolerancePoints * _Point;
   double minClose = DBL_MAX, maxClose = -DBL_MAX; // closes of bars newer than the FVG

   // c = newest bar of the 3-bar pattern, c+2 = oldest
   for(int c = 1; c <= n; c++)
   {
      double top, bottom;
      bool fvg;
      if(isBuy)
      {
         bottom = r[c+2].high;
         top    = r[c].low;
         fvg    = (top > bottom && minClose >= bottom);
      }
      else
      {
         bottom = r[c].high;
         top    = r[c+2].low;
         fvg    = (top > bottom && maxClose <= top);
      }
      if(fvg && price >= bottom - tol && price <= top + tol)
         return true;

      minClose = MathMin(minClose, r[c].close);
      maxClose = MathMax(maxClose, r[c].close);
   }
   return false;
}

//--- True between the configured cut-off and the end of the trading day / week
bool InCutoffWindow()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int nowMin = t.hour * 60 + t.min;

   if(CancelBeforeDailyClose && nowMin >= DailyCancelHour * 60 + DailyCancelMinute)
      return true;
   if(CancelBeforeWeekend && t.day_of_week == 5 && nowMin >= FridayCancelHour * 60 + FridayCancelMinute)
      return true;
   return false;
}

//--- Delete every pending order of this EA on this symbol
void DeleteAllPendingLimits()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(Trade.OrderDelete(t))
         Print("Cut-off: pending order #", t, " deleted before market close.");
   }
   BLimitTicket618 = BLimitTicket705 = BLimitTicket786 = 0;
   LLimitTicket618 = LLimitTicket705 = LLimitTicket786 = 0;
}

//--- Place limit order, return ticket
ulong PlaceLimit(bool isBuy, double price, double sl, double tp, double riskPct, string comment)
{
   if(InCutoffWindow())
   {
      Print(comment, ": limit at ", price, " skipped – inside pre-close cut-off window.");
      return 0;
   }

   if(!HasOrderBlockAt(isBuy, price))
   {
      Print(comment, ": limit at ", price, " skipped – no order block to the left.");
      return 0;
   }

   if(!HasFVGAt(isBuy, price))
   {
      Print(comment, ": limit at ", price, " skipped – no fair value gap to the left.");
      return 0;
   }

   double slPoints = MathAbs(price - sl) / _Point;
   double lots     = CalcLots(riskPct, slPoints);
   if(lots <= 0) return 0;

   Trade.SetExpertMagicNumber(MagicNumber);

   bool ok;
   if(isBuy)
      ok = Trade.BuyLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else
      ok = Trade.SellLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

   if(ok) return Trade.ResultOrder();
   return 0;
}

//--- Move SL to entry once price has moved BreakEvenAtR * initial risk in favour
void ManageBreakEven()
{
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl == 0) continue;

      double beSL = NormalizeDouble(entry, _Digits);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      if(isBuy)
      {
         if(sl >= beSL) continue; // already at or beyond entry
         double risk = entry - sl;
         if(bid - entry >= risk * BreakEvenAtR && bid - beSL > stopsLevel)
            if(Trade.PositionModify(ticket, beSL, tp))
               Print("Break-even: BUY #", ticket, " SL moved to ", beSL);
      }
      else
      {
         if(sl <= beSL) continue;
         double risk = sl - entry;
         if(entry - ask >= risk * BreakEvenAtR && beSL - ask > stopsLevel)
            if(Trade.PositionModify(ticket, beSL, tp))
               Print("Break-even: SELL #", ticket, " SL moved to ", beSL);
      }
   }
}

//--- Close 50% of each position once price has moved PartialCloseAtR * initial risk in favour
void ManagePartialClose()
{
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      ulong  posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

      // Use history so the original SL survives break-even moves and partials aren't repeated after restarts
      if(!HistorySelectByPosition(posId)) continue;
      bool alreadyPartial = false;
      for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
      {
         ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(HistoryDealGetTicket(d), DEAL_ENTRY);
         if(de == DEAL_ENTRY_OUT || de == DEAL_ENTRY_OUT_BY) { alreadyPartial = true; break; }
      }
      if(alreadyPartial) continue;

      double initialSL = PositionGetDouble(POSITION_SL);
      if(initialSL == 0) continue;

      double risk = isBuy ? entry - initialSL : initialSL - entry;
      if(risk <= 0) continue;

      double progress = isBuy ? bid - entry : entry - ask;
      if(progress < risk * PartialCloseAtR) continue;

      // Epsilon guards against float error dropping a lot step (e.g. 0.02 * 0.5 / 0.01 = 0.9999...)
      double closeVol = MathFloor((vol * 0.5) / lotStep + 1e-8) * lotStep;
      if(closeVol < minLot - 1e-8 || vol - closeVol < minLot - 1e-8) continue;

      Trade.SetDeviationInPoints(SlippagePoints);
      if(Trade.PositionClosePartial(ticket, closeVol))
         Print("Partial close: ", (isBuy ? "BUY" : "SELL"), " #", ticket, " closed ", closeVol, " lots at ", PartialCloseAtR, "R");
   }
}

//-------------------------------------------------------------------
// OnInit
//-------------------------------------------------------------------
int OnInit()
{
   if(!IsSupportedTF())
   {
      Alert("CRT OTE EA: Unsupported timeframe. Use H1 or H4.");
      return INIT_FAILED;
   }

   CurrentTF = Period();
   if(CurrentTF == PERIOD_M15)
   {
      HtfTF     = PERIOD_H4;
      ModeLabel = "H4";
   }
   else if(CurrentTF == PERIOD_H1)
   {
      HtfTF     = PERIOD_D1;
      ModeLabel = "Daily";
   }
   else
   {
      HtfTF     = PERIOD_W1;
      ModeLabel = "Weekly";
   }

   Trade.SetExpertMagicNumber(MagicNumber);

   if(UseDailyEMAFilter)
   {
      DailyEMAHandle = iMA(_Symbol, PERIOD_D1, DailyEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(DailyEMAHandle == INVALID_HANDLE)
      {
         Print("CRT OTE EA: failed to create daily EMA handle.");
         return INIT_FAILED;
      }
   }

   if(UsePartialClose)
   {
      double minTpR = DBL_MAX;
      if(UseMarketEntry) minTpR = MathMin(minTpR, TP_R_Market);
      if(UseLimit618)    minTpR = MathMin(minTpR, TP_R_618);
      if(UseLimit705)    minTpR = MathMin(minTpR, TP_R_705);
      if(UseLimit786)    minTpR = MathMin(minTpR, TP_R_786);
      if(PartialCloseAtR >= minTpR)
         Print("WARNING: PartialCloseAtR (", PartialCloseAtR, ") >= TP R (", minTpR,
               ") – TP will close the position before the partial close can trigger.");
   }

   // Init state
   PeriodHigh             = 0;
   PeriodLow              = 0;
   PeriodTouchedBelowHtfH = false;
   PeriodTouchedAboveHtfL = false;
   LastPeriodTime         = 0;
   BLimitTicket618        = 0;
   BLimitTicket705        = 0;
   BLimitTicket786        = 0;
   LLimitTicket618        = 0;
   LLimitTicket705        = 0;
   LLimitTicket786        = 0;

   ResetBear();
   ResetBull();

   Print("CRT OTE EA initialised – TF:", EnumToString(CurrentTF), " HTF:", EnumToString(HtfTF));
   return INIT_SUCCEEDED;
}

//-------------------------------------------------------------------
// OnDeinit
//-------------------------------------------------------------------
void OnDeinit(const int reason)
{
   // Leave orders open on deinit – broker manages them
   if(DailyEMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(DailyEMAHandle);
      DailyEMAHandle = INVALID_HANDLE;
   }
}

//-------------------------------------------------------------------
// OnTick  – main logic runs on confirmed (closed) bars only
//-------------------------------------------------------------------
void OnTick()
{
   if(!IsSupportedTF()) return;

   if(UsePartialClose) ManagePartialClose();
   if(UseBreakEven) ManageBreakEven();
   if(InCutoffWindow()) DeleteAllPendingLimits();

   // ── Work on the last CLOSED bar (shift=1) to avoid repainting ──
   // We detect a new bar by comparing bar open times
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, CurrentTF, 0);
   if(currentBarTime == lastBarTime) return; // same bar, nothing new
   lastBarTime = currentBarTime;

   // Now bar[1] is the newly closed bar
   // Current incomplete bar is bar[0]

   FetchHtfLevels();
   if(HtfHigh == 0 || HtfLow == 0) return;

   // ── Detect new HTF period ──
   datetime htfBarTime = iTime(_Symbol, HtfTF, 0);
   bool isNewPeriod    = (htfBarTime != LastPeriodTime);

   if(isNewPeriod)
   {
      LastPeriodTime = htfBarTime;

      // Reset for the new period
      PeriodHigh = iHigh(_Symbol, CurrentTF, 1);
      PeriodLow  = iLow (_Symbol, CurrentTF, 1);

      // Check if first bar already touches HTF levels
      PeriodTouchedBelowHtfH = (PeriodLow  <= HtfHigh);
      PeriodTouchedAboveHtfL = (PeriodHigh >= HtfLow);

      ResetBear();
      ResetBull();
   }
   else
   {
      // Update running period high/low with the newly closed bar
      double barHigh = iHigh(_Symbol, CurrentTF, 1);
      double barLow  = iLow (_Symbol, CurrentTF, 1);
      if(PeriodHigh == 0) PeriodHigh = barHigh;
      if(PeriodLow  == 0 || PeriodLow > barLow) PeriodLow = barLow;
      PeriodHigh = MathMax(PeriodHigh, barHigh);
      PeriodLow  = MathMin(PeriodLow,  barLow);

      if(barLow  <= HtfHigh) PeriodTouchedBelowHtfH = true;
      if(barHigh >= HtfLow)  PeriodTouchedAboveHtfL = true;
   }

   int currentBarIndex = Bars(_Symbol, CurrentTF) - 1; // proxy for bar_index
   // Use the closed bar's index as reference
   int closedBarIdx = currentBarIndex - 1;

   double barHigh1  = iHigh (_Symbol, CurrentTF, 1);
   double barLow1   = iLow  (_Symbol, CurrentTF, 1);
   double barClose1 = iClose(_Symbol, CurrentTF, 1);

   //================================================================
   // BEARISH CRT STATE MACHINE
   //================================================================
   if(AllowShorts && !BPeriodDone)
   {
      //--- State 0: scanning for HTF-High sweep
      if(BState == 0 && barHigh1 > HtfHigh && PeriodTouchedBelowHtfH)
      {
         BSweepHigh  = barHigh1;
         BSweepClose = barLow1;   // sweep candle low
         BSweepBar   = closedBarIdx;
         BState      = 1;
         Print("Bear CRT: HTF-High swept at ", BSweepHigh, " [", ModeLabel, "]");
      }

      //--- State 1: waiting for confirmation
      else if(BState == 1 && closedBarIdx > BSweepBar)
      {
         if(barClose1 < BSweepClose)
         {
            // Confirmation – compute Fibonacci levels
            double confirmLow = barLow1;
            double fibRange   = PeriodHigh - confirmLow;

            BShort618 = confirmLow + 0.618 * fibRange;
            BShort705 = confirmLow + 0.705 * fibRange;
            BShort786 = confirmLow + 0.786 * fibRange;
            BSL       = PeriodHigh + SlBufferPoints * _Point;

            double marketAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            // Validate: entry prices must be above current price and TP below entry
            if(!DailyEMAAllows(false))
            {
               Print("Bear CRT: confirmation skipped – daily close not below ", DailyEMAPeriod, " EMA.");
               BState = 0;
            }
            else if(BShort618 > marketAsk && BShort705 > marketAsk)
            {
               BConfirmBar = closedBarIdx;
               BState      = 2;
               BPeriodDone = true;

               // ── Entry #1: Market sell immediately ──
               if(UseMarketEntry)
               {
                  double tp1 = marketAsk - (BSL - marketAsk) * TP_R_Market;
                  PlaceMarket(false, BSL, tp1, RiskPct_Market, TradeComment + "_MKT");
                  Print("Bear CRT: Market SELL placed. SL=", BSL, " TP=", tp1);
               }

               // ── Entry #2: Sell Limit at 0.618 ──
               if(UseLimit618)
               {
                  double tp2 = BShort618 - (BSL - BShort618) * TP_R_618;
                  BLimitTicket618 = PlaceLimit(false, BShort618, BSL, tp2, RiskPct_618, TradeComment + "_618");
                  Print("Bear CRT: Sell Limit 0.618 at ", BShort618, " TP=", tp2, " Ticket=", BLimitTicket618);
               }

               // ── Entry #3: Sell Limit at 0.705 ──
               if(UseLimit705)
               {
                  double tp3 = BShort705 - (BSL - BShort705) * TP_R_705;
                  BLimitTicket705 = PlaceLimit(false, BShort705, BSL, tp3, RiskPct_705, TradeComment + "_705");
                  Print("Bear CRT: Sell Limit 0.705 at ", BShort705, " TP=", tp3, " Ticket=", BLimitTicket705);
               }

               // ── Entry #4: Sell Limit at 0.786 ──
               if(UseLimit786)
               {
                  double tp4 = BShort786 - (BSL - BShort786) * TP_R_786;
                  BLimitTicket786 = PlaceLimit(false, BShort786, BSL, tp4, RiskPct_786, TradeComment + "_786");
                  Print("Bear CRT: Sell Limit 0.786 at ", BShort786, " TP=", tp4, " Ticket=", BLimitTicket786);
               }
            }
            else
            {
               BState = 0; // invalid, rescan
            }
         }
         else if(barHigh1 > HtfHigh)
         {
            // Continued sweep – extend
            if(barHigh1 > BSweepHigh) BSweepHigh = barHigh1;
            BSweepBar = closedBarIdx;
         }
         else if(closedBarIdx - BSweepBar >= MaxConfirmBars)
         {
            BState = 0; // timeout
         }
      }

      //--- State 2: orders are live – monitor for fib update or invalidation
      else if((BState == 2 || BState == 3) && closedBarIdx > BConfirmBar)
      {
         // If price drops further below sweep close but hasn't touched 0.618 yet
         // → update fib levels and reposition limits
         if(BState == 2 && barLow1 < BSweepClose && barHigh1 < BShort618)
         {
            BSweepClose = barLow1;
            double fibRange = PeriodHigh - BSweepClose;
            double new618   = BSweepClose + 0.618 * fibRange;
            double new705   = BSweepClose + 0.705 * fibRange;
            double new786   = BSweepClose + 0.786 * fibRange;

            // Reposition limits if still pending
            if(OrderExists(BLimitTicket618) && HasOrderBlockAt(false, new618) && HasFVGAt(false, new618))
            {
               CancelOrder(BLimitTicket618);
               double tp2 = new618 - (BSL - new618) * TP_R_618;
               BLimitTicket618 = PlaceLimit(false, new618, BSL, tp2, RiskPct_618, TradeComment + "_618");
            }
            if(OrderExists(BLimitTicket705) && HasOrderBlockAt(false, new705) && HasFVGAt(false, new705))
            {
               CancelOrder(BLimitTicket705);
               double tp3 = new705 - (BSL - new705) * TP_R_705;
               BLimitTicket705 = PlaceLimit(false, new705, BSL, tp3, RiskPct_705, TradeComment + "_705");
            }
            if(OrderExists(BLimitTicket786) && HasOrderBlockAt(false, new786) && HasFVGAt(false, new786))
            {
               CancelOrder(BLimitTicket786);
               double tp4 = new786 - (BSL - new786) * TP_R_786;
               BLimitTicket786 = PlaceLimit(false, new786, BSL, tp4, RiskPct_786, TradeComment + "_786");
            }
            BShort618 = new618;
            BShort705 = new705;
            BShort786 = new786;
         }

         // Price reached 0.618: freeze fibs but keep deeper limits working
         if(BState == 2 && barHigh1 > BShort618)
         {
            Print("Bear CRT: Price reached 0.618 – fib levels frozen.");
            BState = 3;
         }

         // Hard invalidation: close above SL
         if(barClose1 > BSL)
         {
            Print("Bear CRT: SL breached on close. Cancelling limits.");
            CancelBearLimits();
            BState = 4;
         }
      }
   }

   //================================================================
   // BULLISH CRT STATE MACHINE
   //================================================================
   if(AllowLongs && !LPeriodDone)
   {
      //--- State 0: scanning for HTF-Low sweep
      if(LState == 0 && barLow1 < HtfLow && PeriodTouchedAboveHtfL)
      {
         LSweepLow   = barLow1;
         LSweepClose = barHigh1;  // sweep candle high
         LSweepBar   = closedBarIdx;
         LState      = 1;
         Print("Bull CRT: HTF-Low swept at ", LSweepLow, " [", ModeLabel, "]");
      }

      //--- State 1: waiting for confirmation
      else if(LState == 1 && closedBarIdx > LSweepBar)
      {
         if(barClose1 > LSweepClose)
         {
            double confirmHigh = barHigh1;
            double fibRange    = confirmHigh - PeriodLow;

            LLong618 = confirmHigh - 0.618 * fibRange;
            LLong705 = confirmHigh - 0.705 * fibRange;
            LLong786 = confirmHigh - 0.786 * fibRange;
            LSL      = PeriodLow - SlBufferPoints * _Point;

            double marketBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

            if(!DailyEMAAllows(true))
            {
               Print("Bull CRT: confirmation skipped – daily close not above ", DailyEMAPeriod, " EMA.");
               LState = 0;
            }
            else if(LLong618 < marketBid && LLong705 < marketBid)
            {
               LConfirmBar = closedBarIdx;
               LState      = 2;
               LPeriodDone = true;

               // ── Entry #1: Market buy immediately ──
               if(UseMarketEntry)
               {
                  double tp1 = marketBid + (marketBid - LSL) * TP_R_Market;
                  PlaceMarket(true, LSL, tp1, RiskPct_Market, TradeComment + "_MKT");
                  Print("Bull CRT: Market BUY placed. SL=", LSL, " TP=", tp1);
               }

               // ── Entry #2: Buy Limit at 0.618 ──
               if(UseLimit618)
               {
                  double tp2 = LLong618 + (LLong618 - LSL) * TP_R_618;
                  LLimitTicket618 = PlaceLimit(true, LLong618, LSL, tp2, RiskPct_618, TradeComment + "_618");
                  Print("Bull CRT: Buy Limit 0.618 at ", LLong618, " TP=", tp2, " Ticket=", LLimitTicket618);
               }

               // ── Entry #3: Buy Limit at 0.705 ──
               if(UseLimit705)
               {
                  double tp3 = LLong705 + (LLong705 - LSL) * TP_R_705;
                  LLimitTicket705 = PlaceLimit(true, LLong705, LSL, tp3, RiskPct_705, TradeComment + "_705");
                  Print("Bull CRT: Buy Limit 0.705 at ", LLong705, " TP=", tp3, " Ticket=", LLimitTicket705);
               }

               // ── Entry #4: Buy Limit at 0.786 ──
               if(UseLimit786)
               {
                  double tp4 = LLong786 + (LLong786 - LSL) * TP_R_786;
                  LLimitTicket786 = PlaceLimit(true, LLong786, LSL, tp4, RiskPct_786, TradeComment + "_786");
                  Print("Bull CRT: Buy Limit 0.786 at ", LLong786, " TP=", tp4, " Ticket=", LLimitTicket786);
               }
            }
            else
            {
               LState = 0;
            }
         }
         else if(barLow1 < HtfLow)
         {
            if(barLow1 < LSweepLow) LSweepLow = barLow1;
            LSweepBar = closedBarIdx;
         }
         else if(closedBarIdx - LSweepBar >= MaxConfirmBars)
         {
            LState = 0;
         }
      }

      //--- State 2: orders live – monitor for fib update or invalidation
      else if((LState == 2 || LState == 3) && closedBarIdx > LConfirmBar)
      {
         // If price extends sweep high but hasn't touched 0.618 → update fibs
         if(LState == 2 && barHigh1 > LSweepClose && barLow1 > LLong618)
         {
            LSweepClose = barHigh1;
            double fibRange = LSweepClose - PeriodLow;
            double new618   = LSweepClose - 0.618 * fibRange;
            double new705   = LSweepClose - 0.705 * fibRange;
            double new786   = LSweepClose - 0.786 * fibRange;

            if(OrderExists(LLimitTicket618) && HasOrderBlockAt(true, new618) && HasFVGAt(true, new618))
            {
               CancelOrder(LLimitTicket618);
               double tp2 = new618 + (new618 - LSL) * TP_R_618;
               LLimitTicket618 = PlaceLimit(true, new618, LSL, tp2, RiskPct_618, TradeComment + "_618");
            }
            if(OrderExists(LLimitTicket705) && HasOrderBlockAt(true, new705) && HasFVGAt(true, new705))
            {
               CancelOrder(LLimitTicket705);
               double tp3 = new705 + (new705 - LSL) * TP_R_705;
               LLimitTicket705 = PlaceLimit(true, new705, LSL, tp3, RiskPct_705, TradeComment + "_705");
            }
            if(OrderExists(LLimitTicket786) && HasOrderBlockAt(true, new786) && HasFVGAt(true, new786))
            {
               CancelOrder(LLimitTicket786);
               double tp4 = new786 + (new786 - LSL) * TP_R_786;
               LLimitTicket786 = PlaceLimit(true, new786, LSL, tp4, RiskPct_786, TradeComment + "_786");
            }
            LLong618 = new618;
            LLong705 = new705;
            LLong786 = new786;
         }

         // Price reached 0.618: freeze fibs but keep deeper limits working
         if(LState == 2 && barLow1 < LLong618)
         {
            Print("Bull CRT: Price reached 0.618 – fib levels frozen.");
            LState = 3;
         }

         // Hard invalidation: close below SL
         if(barClose1 < LSL)
         {
            Print("Bull CRT: SL breached on close. Cancelling limits.");
            CancelBullLimits();
            LState = 4;
         }
      }
   }
}

//+------------------------------------------------------------------+
