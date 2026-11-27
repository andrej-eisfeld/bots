//+------------------------------------------------------------------+
//|                                              TurtleTrader_EA.mq5  |
//|            Turtle Trading System Expert Advisor (S1 + S2)         |
//|                                                                  |
//|  Based on:                                                        |
//|    * "Turtle Trade Channels Indicator" (TuTCI) by @kivancozbilgic |
//|    * The original Turtle Trading rules (Dennis / Faith).          |
//|                                                                  |
//|  Concept                                                          |
//|  -------                                                          |
//|  Donchian channel breakout system with two sub-systems:           |
//|                                                                  |
//|     System 1 (S1):  Entry = 20-bar breakout, Exit = 10-bar        |
//|     System 2 (S2):  Entry = 55-bar breakout, Exit = 20-bar        |
//|                                                                  |
//|  Entry                                                            |
//|     * Go LONG  when price breaks ABOVE the highest high of the    |
//|       previous <EntryPeriod> bars.                                |
//|     * Go SHORT when price breaks BELOW the lowest low of the      |
//|       previous <EntryPeriod> bars.                                |
//|                                                                  |
//|  S1 filter (original rule)                                        |
//|     * Take an S1 breakout ONLY if the last S1 signal would have   |
//|       been a LOSS.  If the last S1 signal was a winner, skip it   |
//|       (whether or not it was actually traded).                    |
//|     * S2 (the fail-safe) breakouts are ALWAYS taken.              |
//|                                                                  |
//|  Exit                                                             |
//|     * Close LONG  when price breaks below the lowest low of the   |
//|       previous <ExitPeriod> bars.                                 |
//|     * Close SHORT when price breaks above the highest high of the |
//|       previous <ExitPeriod> bars.                                 |
//|                                                                  |
//|  Risk                                                             |
//|     * N = ATR(period).  Initial stop = EntryPrice -/+ 2N.          |
//|     * Volatility position sizing: one Unit is sized so a 1N move  |
//|       equals a fixed % of account equity.                         |
//|     * Optional pyramiding: add Units every 0.5N in the trade's    |
//|       favour (up to a max), trailing all stops to 2N from the     |
//|       most recent Unit.                                           |
//+------------------------------------------------------------------+
#property copyright "Turtle Trader EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//====================== INPUTS ========================================
input group "=== General ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // Working timeframe (Turtles used D1)

input group "=== System 1 (fast) ==="
input bool InpUseS1      = true;  // Trade System 1
input int  InpEntryS1    = 20;    // S1 entry breakout length
input int  InpExitS1     = 10;    // S1 exit breakout length
input bool InpUseS1Filter= true;  // Skip S1 entry if last S1 signal was a WIN

input group "=== System 2 (fail-safe) ==="
input bool InpUseS2      = true;  // Trade System 2
input int  InpEntryS2    = 55;    // S2 entry breakout length
input int  InpExitS2     = 20;    // S2 exit breakout length

input group "=== Volatility / Stops (N) ==="
input int    InpATRPeriod   = 20;   // ATR period (N)
input double InpStopN       = 2.0;  // Initial stop distance in N (ATR) units
input bool   InpUseHardStop = true; // Attach a 2N hard stop-loss order

input group "=== Position Sizing ==="
input bool   InpUseRiskSizing   = true; // Size by volatility (% risk per 1N)
input double InpRiskPerN_Percent= 1.0;  // % of equity risked per 1N move (Unit)
input double InpFixedLot         = 0.10;// Fixed lot (when risk sizing off)
input double InpMaxLot           = 100; // Hard cap on lot size

input group "=== Pyramiding (adding units) ==="
input bool   InpUsePyramiding = false; // Add units as the trade moves in favour
input int    InpMaxUnits      = 4;     // Max units per direction (incl. first)
input double InpAddStepN      = 0.5;   // Add another unit every this many N

input group "=== Trade Control ==="
input long   InpMagic          = 990046; // Magic number
input int    InpSlippagePoints = 30;     // Max slippage (points)
input int    InpMaxSpreadPoints= 0;      // Max spread in points (0 = ignore)
input string InpTradeComment   = "TURTLE";
input bool   InpTradeMonday    = false;  // Allow new entries on Monday (server time)
input bool   InpTradeFriday    = false;  // Allow new entries on Friday (server time)

//====================== GLOBALS =======================================
CTrade          gTrade;
ENUM_TIMEFRAMES gTF;
string          gSym;
datetime        gLastBarTime = 0;
int             gATRHandle   = INVALID_HANDLE;

// --- Phantom S1 tracker (drives the "last S1 signal was a win" filter) ---
bool   gPhantActive   = false;   // a phantom S1 trade is currently open
int    gPhantDir      = 0;       // +1 long / -1 short
double gPhantEntry    = 0.0;     // phantom entry (breakout level)
double gPhantStop     = 0.0;     // phantom 2N stop
bool   gHaveS1Result  = false;   // do we have a completed S1 signal yet?
bool   gLastS1Win     = false;   // outcome of the most recent completed S1 signal

//+------------------------------------------------------------------+
//| Highest high over 'count' bars starting at 'startShift'          |
//+------------------------------------------------------------------+
double DonchianHigh(int count, int startShift)
{
   double m = -DBL_MAX;
   for(int i = 0; i < count; i++)
   {
      double h = iHigh(gSym, gTF, startShift + i);
      if(h > m) m = h;
   }
   return m;
}

//+------------------------------------------------------------------+
//| Lowest low over 'count' bars starting at 'startShift'            |
//+------------------------------------------------------------------+
double DonchianLow(int count, int startShift)
{
   double m = DBL_MAX;
   for(int i = 0; i < count; i++)
   {
      double l = iLow(gSym, gTF, startShift + i);
      if(l > 0.0 && l < m) m = l;
   }
   return m;
}

//+------------------------------------------------------------------+
//| Current N (ATR) value on the last closed bar                     |
//+------------------------------------------------------------------+
double GetN()
{
   double buf[];
   if(CopyBuffer(gATRHandle, 0, 1, 1, buf) < 1)
      return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   gSym = _Symbol;
   gTF  = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe;

   gATRHandle = iATR(gSym, gTF, InpATRPeriod);
   if(gATRHandle == INVALID_HANDLE)
   {
      Print("[TURTLE] Failed to create ATR handle.");
      return(INIT_FAILED);
   }

   gTrade.SetExpertMagicNumber(InpMagic);
   gTrade.SetDeviationInPoints(InpSlippagePoints);
   gTrade.SetTypeFillingBySymbol(gSym);
   gTrade.SetAsyncMode(false);

   gLastBarTime = iTime(gSym, gTF, 0);

   PrintFormat("[TURTLE] Initialized on %s  TF=%s  S1(%d/%d)=%s  S2(%d/%d)=%s",
               gSym, EnumToString(gTF),
               InpEntryS1, InpExitS1, (InpUseS1 ? "on" : "off"),
               InpEntryS2, InpExitS2, (InpUseS2 ? "on" : "off"));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(gATRHandle != INVALID_HANDLE)
      IndicatorRelease(gATRHandle);
}

//+------------------------------------------------------------------+
//| Is the symbol currently tradeable (session open + permissions)?  |
//+------------------------------------------------------------------+
bool IsMarketOpen()
{
   // Terminal / account / program trade permissions.
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return false;

   long tmode = SymbolInfoInteger(gSym, SYMBOL_TRADE_MODE);
   if(tmode == SYMBOL_TRADE_MODE_DISABLED) return false;

   // Is 'now' inside one of the symbol's trading sessions for today?
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   int secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;

   datetime from = 0, to = 0;
   bool haveSession = false;
   for(int s = 0; SymbolInfoSessionTrade(gSym, dow, s, from, to); s++)
   {
      haveSession = true;
      if(secOfDay >= (int)from && secOfDay < (int)to)
         return true;
   }

   // If the broker exposes no session data, don't block trading.
   return !haveSession;
}

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   double point = SymbolInfoDouble(gSym, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(gSym, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(gSym, SYMBOL_BID);
   return ((ask - bid) / point <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Normalize a lot size to the symbol constraints                   |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(gSym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(gSym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(gSym, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) stepLot = 0.01;

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathMin(lot, InpMaxLot);
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Unit lot size from N (volatility position sizing)                |
//+------------------------------------------------------------------+
double CalcUnitLot(double n)
{
   if(!InpUseRiskSizing || n <= 0.0)
      return NormalizeLot(InpFixedLot);

   double tickValue = SymbolInfoDouble(gSym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(gSym, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return NormalizeLot(InpFixedLot);

   double equity            = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney         = equity * InpRiskPerN_Percent / 100.0;
   double moneyPerPriceLot  = tickValue / tickSize;   // account money per 1.0 price move, per lot
   double moneyPerN_perLot  = n * moneyPerPriceLot;   // value of a 1N move per lot
   if(moneyPerN_perLot <= 0.0)
      return NormalizeLot(InpFixedLot);

   double lot = riskMoney / moneyPerN_perLot;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Own-position helpers                                             |
//+------------------------------------------------------------------+
bool SelectOwn(int index)
{
   ulong ticket = PositionGetTicket(index);
   if(ticket == 0)                                        return false;
   if(PositionGetString(POSITION_SYMBOL) != gSym)         return false;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic)     return false;
   return true;
}

int CountOwn(int dir)   // dir: +1 long, -1 short, 0 = any
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i)) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir == 0 ||
         (dir > 0 && type == POSITION_TYPE_BUY) ||
         (dir < 0 && type == POSITION_TYPE_SELL))
         c++;
   }
   return c;
}

// Most extreme entry among own positions of a direction
// (highest entry for longs, lowest entry for shorts) -> last added unit.
double LastUnitEntry(int dir)
{
   double best = (dir > 0) ? -DBL_MAX : DBL_MAX;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i)) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type != POSITION_TYPE_BUY)  continue;
      if(dir < 0 && type != POSITION_TYPE_SELL) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(dir > 0) { if(e > best) best = e; }
      else        { if(e < best) best = e; }
      found = true;
   }
   return found ? best : 0.0;
}

// Does the position's comment mark it as System 2?
bool IsS2Comment(string comment)
{
   return (StringFind(comment, "S2") >= 0);
}

//+------------------------------------------------------------------+
//| Close every own position of a given direction                    |
//+------------------------------------------------------------------+
void CloseDirection(int dir, string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i)) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type != POSITION_TYPE_BUY)  continue;
      if(dir < 0 && type != POSITION_TYPE_SELL) continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(gTrade.PositionClose(ticket))
         PrintFormat("[TURTLE] Closed #%I64u (%s).", ticket, reason);
   }
}

//+------------------------------------------------------------------+
//| Move all stops of a direction to a new level                     |
//+------------------------------------------------------------------+
void TrailStops(int dir, double newStop)
{
   int    digits = (int)SymbolInfoInteger(gSym, SYMBOL_DIGITS);
   newStop = NormalizeDouble(newStop, digits);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i)) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type != POSITION_TYPE_BUY)  continue;
      if(dir < 0 && type != POSITION_TYPE_SELL) continue;
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      ulong  tk    = PositionGetInteger(POSITION_TICKET);
      // Only tighten in the trade's favour.
      bool improve = (dir > 0) ? (newStop > curSL) : (newStop < curSL || curSL == 0.0);
      if(dir > 0 && curSL == 0.0) improve = true;
      if(improve)
         gTrade.PositionModify(tk, newStop, tp);
   }
}

//+------------------------------------------------------------------+
//| Update the phantom S1 signal tracker (the S1 win/loss filter)    |
//+------------------------------------------------------------------+
void UpdatePhantomS1(double n)
{
   if(n <= 0.0) return;

   double h1 = iHigh(gSym, gTF, 1);
   double l1 = iLow (gSym, gTF, 1);

   double entryHigh = DonchianHigh(InpEntryS1, 2); // 20-bar high of bars before the closed bar
   double entryLow  = DonchianLow (InpEntryS1, 2);
   double exitLow   = DonchianLow (InpExitS1,  2);
   double exitHigh  = DonchianHigh(InpExitS1,  2);
   double stopDist  = InpStopN * n;

   if(!gPhantActive)
   {
      if(h1 >= entryHigh)
      {
         gPhantActive = true; gPhantDir = 1;
         gPhantEntry  = entryHigh;  gPhantStop = entryHigh - stopDist;
      }
      else if(l1 <= entryLow)
      {
         gPhantActive = true; gPhantDir = -1;
         gPhantEntry  = entryLow;   gPhantStop = entryLow + stopDist;
      }
      return;
   }

   // Manage the open phantom trade.
   if(gPhantDir == 1)
   {
      bool stopHit = (l1 <= gPhantStop);
      bool chanOut = (l1 <= exitLow);
      if(stopHit || chanOut)
      {
         double exitPrice = stopHit ? gPhantStop : exitLow;
         gLastS1Win    = (exitPrice > gPhantEntry);
         gHaveS1Result = true;
         gPhantActive  = false;
      }
   }
   else
   {
      bool stopHit = (h1 >= gPhantStop);
      bool chanOut = (h1 >= exitHigh);
      if(stopHit || chanOut)
      {
         double exitPrice = stopHit ? gPhantStop : exitHigh;
         gLastS1Win    = (exitPrice < gPhantEntry);
         gHaveS1Result = true;
         gPhantActive  = false;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage exits for open positions (opposite Donchian channel)      |
//+------------------------------------------------------------------+
void ManageExits()
{
   double h1 = iHigh(gSym, gTF, 1);
   double l1 = iLow (gSym, gTF, 1);

   // Determine which exit period governs each open direction by
   // inspecting the position comments (S2 uses the wider channel).
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectOwn(i)) continue;
      long   type    = PositionGetInteger(POSITION_TYPE);
      string comment = PositionGetString(POSITION_COMMENT);
      int    exitLen = IsS2Comment(comment) ? InpExitS2 : InpExitS1;

      if(type == POSITION_TYPE_BUY)
      {
         double exitLow = DonchianLow(exitLen, 2);
         if(l1 <= exitLow)
         {
            ulong tk = PositionGetInteger(POSITION_TICKET);
            if(gTrade.PositionClose(tk))
               PrintFormat("[TURTLE] LONG exit #%I64u (%d-bar low breach).", tk, exitLen);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double exitHigh = DonchianHigh(exitLen, 2);
         if(h1 >= exitHigh)
         {
            ulong tk = PositionGetInteger(POSITION_TICKET);
            if(gTrade.PositionClose(tk))
               PrintFormat("[TURTLE] SHORT exit #%I64u (%d-bar high breach).", tk, exitLen);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open a Unit in the given direction                               |
//+------------------------------------------------------------------+
void OpenUnit(int dir, bool isS2, double n)
{
   if(!SpreadOK())
   {
      Print("[TURTLE] Entry skipped: spread too high.");
      return;
   }

   int    digits = (int)SymbolInfoInteger(gSym, SYMBOL_DIGITS);
   double lot    = CalcUnitLot(n);
   if(lot <= 0.0) return;

   string comment = InpTradeComment + (isS2 ? "_S2" : "_S1");
   double stopDist = InpStopN * n;

   if(dir > 0)
   {
      double entry = SymbolInfoDouble(gSym, SYMBOL_ASK);
      double sl    = InpUseHardStop ? NormalizeDouble(entry - stopDist, digits) : 0.0;
      if(gTrade.Buy(lot, gSym, entry, sl, 0.0, comment))
         PrintFormat("[TURTLE] LONG %s Unit. lot=%.2f entry=%.5f SL=%.5f N=%.5f",
                     (isS2 ? "S2" : "S1"), lot, entry, sl, n);
      else
         PrintFormat("[TURTLE] LONG failed. ret=%d %s",
                     gTrade.ResultRetcode(), gTrade.ResultRetcodeDescription());
   }
   else
   {
      double entry = SymbolInfoDouble(gSym, SYMBOL_BID);
      double sl    = InpUseHardStop ? NormalizeDouble(entry + stopDist, digits) : 0.0;
      if(gTrade.Sell(lot, gSym, entry, sl, 0.0, comment))
         PrintFormat("[TURTLE] SHORT %s Unit. lot=%.2f entry=%.5f SL=%.5f N=%.5f",
                     (isS2 ? "S2" : "S1"), lot, entry, sl, n);
      else
         PrintFormat("[TURTLE] SHORT failed. ret=%d %s",
                     gTrade.ResultRetcode(), gTrade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Pyramiding: add units as the trade extends in its favour         |
//+------------------------------------------------------------------+
void ManagePyramiding(double n)
{
   if(!InpUsePyramiding || n <= 0.0) return;

   double c1   = iClose(gSym, gTF, 1);
   double step = InpAddStepN * n;

   int longUnits = CountOwn(+1);
   if(longUnits > 0 && longUnits < InpMaxUnits)
   {
      double lastEntry = LastUnitEntry(+1);
      if(lastEntry > 0.0 && c1 >= lastEntry + step)
      {
         bool isS2 = false; // inherit governing system from existing units
         for(int i = PositionsTotal() - 1; i >= 0; i--)
            if(SelectOwn(i) && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
               { isS2 = IsS2Comment(PositionGetString(POSITION_COMMENT)); break; }
         OpenUnit(+1, isS2, n);
         TrailStops(+1, iClose(gSym, gTF, 1) - InpStopN * n);
      }
   }

   int shortUnits = CountOwn(-1);
   if(shortUnits > 0 && shortUnits < InpMaxUnits)
   {
      double lastEntry = LastUnitEntry(-1);
      if(lastEntry > 0.0 && c1 <= lastEntry - step)
      {
         bool isS2 = false;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
            if(SelectOwn(i) && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
               { isS2 = IsS2Comment(PositionGetString(POSITION_COMMENT)); break; }
         OpenUnit(-1, isS2, n);
         TrailStops(-1, iClose(gSym, gTF, 1) + InpStopN * n);
      }
   }
}

//+------------------------------------------------------------------+
//| Evaluate breakout entries                                        |
//+------------------------------------------------------------------+
void EvaluateEntries(double n)
{
   // Only open a fresh position when flat (no own positions either way).
   if(CountOwn(0) > 0)
      return;

   double h1 = iHigh(gSym, gTF, 1);
   double l1 = iLow (gSym, gTF, 1);

   double entryHighS1 = DonchianHigh(InpEntryS1, 2);
   double entryLowS1  = DonchianLow (InpEntryS1, 2);
   double entryHighS2 = DonchianHigh(InpEntryS2, 2);
   double entryLowS2  = DonchianLow (InpEntryS2, 2);

   bool s1Allowed = !InpUseS1Filter || !gHaveS1Result || !gLastS1Win;

   // ----- LONG -----
   bool longS2 = InpUseS2 && (h1 >= entryHighS2);
   bool longS1 = InpUseS1 && s1Allowed && (h1 >= entryHighS1);
   if(longS2 || longS1)
   {
      OpenUnit(+1, longS2, n);   // prefer S2 (wider exit) when both trigger
      return;
   }

   // ----- SHORT -----
   bool shortS2 = InpUseS2 && (l1 <= entryLowS2);
   bool shortS1 = InpUseS1 && s1Allowed && (l1 <= entryLowS1);
   if(shortS2 || shortS1)
   {
      OpenUnit(-1, shortS2, n);
      return;
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // Act once per newly closed bar of the working timeframe.
   datetime t = iTime(gSym, gTF, 0);
   if(t == gLastBarTime)
      return;

   // Defer until the symbol is actually tradeable. Do NOT consume the bar
   // yet, so the same bar's logic re-runs once the session opens (this
   // avoids retcode 10018 "market closed" at the daily rollover).
   if(!IsMarketOpen())
      return;

   gLastBarTime = t;

   int needBars = MathMax(InpEntryS2, MathMax(InpEntryS1, InpATRPeriod)) + 5;
   if(Bars(gSym, gTF) < needBars)
      return;

   double n = GetN();
   if(n <= 0.0)
      return;

   // Order matters: keep the S1 filter current, exit, add, then enter.
   UpdatePhantomS1(n);
   ManageExits();

   // Exits are still managed on blocked days; only new risk is skipped.
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if((dt.day_of_week == MONDAY && !InpTradeMonday) ||
      (dt.day_of_week == FRIDAY && !InpTradeFriday))
      return;

   ManagePyramiding(n);
   EvaluateEntries(n);
}
//+------------------------------------------------------------------+
