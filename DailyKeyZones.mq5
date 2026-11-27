//+------------------------------------------------------------------+
//|                                Daily_EMA_Zone_Engulfing_EA.mq5   |
//|   1) Price above/below the daily 50 EMA                          |
//|   2) Price inside a daily order block or FVG                     |
//|   3) Engulfing candle on the signal (lower) timeframe            |
//|   SL beyond the engulfed candle (optionally ATR based),          |
//|   TP at a configurable R:R multiple.                             |
//+------------------------------------------------------------------+
#property copyright "Daily EMA + OB/FVG + Engulfing EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_LOT_MODE
{
   LOT_FIXED        = 0, // Fixed lots
   LOT_RISK_PERCENT = 1  // Risk % of balance per trade
};

enum ENUM_SL_MODE
{
   SL_CANDLE          = 0, // Beyond engulfed candle
   SL_ATR             = 1, // ATR distance from entry
   SL_CANDLE_PLUS_ATR = 2  // Beyond engulfed candle + ATR buffer
};

enum ENUM_ZONE_MODE
{
   ZONE_OB_AND_FVG = 0, // Order blocks and FVGs
   ZONE_OB_ONLY    = 1, // Order blocks only
   ZONE_FVG_ONLY   = 2  // FVGs only
};

input group "Trend filter"
input ENUM_TIMEFRAMES InpHTF       = PERIOD_D1; // Higher timeframe (EMA + zones)
input int             InpEMAPeriod = 50;        // EMA period

input group "Daily zones"
input ENUM_ZONE_MODE InpZoneMode        = ZONE_OB_AND_FVG; // Zone types
input int            InpZoneLookback    = 30;              // HTF bars to scan for zones
input bool           InpRemoveMitigated = true;            // Ignore zones broken by an HTF close

input group "Entry"
input ENUM_TIMEFRAMES InpSignalTF   = PERIOD_CURRENT; // Engulfing (signal) timeframe
input bool            InpEnableBuy  = true;           // Enable longs
input bool            InpEnableSell = true;           // Enable shorts
input bool            InpOnePosition = true;          // Only one open position at a time

input group "Volume filter"
input bool InpUseVolumeFilter = true; // Require above-average volume on engulfing candle
input int  InpVolumePeriod    = 20;   // Bars for average volume

input group "Stop loss / Take profit"
input ENUM_SL_MODE InpSLMode       = SL_CANDLE; // Stop loss mode
input bool         InpSLUsePattern = false;     // Use extreme of both candles (not only engulfed)
input double       InpSLBufferPips = 1.0;       // Extra buffer beyond candle (pips)
input int          InpATRPeriod    = 14;        // ATR period (signal timeframe)
input double       InpATRMult      = 1.0;       // ATR multiplier
input double       InpRiskReward   = 2.0;       // Risk:Reward ratio

input group "Breakeven"
input bool   InpUseBreakeven = false; // Move SL to breakeven
input double InpBETriggerRR  = 1.0;   // Trigger at this R multiple
input double InpBEOffsetPips = 0.0;   // Lock-in offset beyond entry (pips)

input group "Money management"
input ENUM_LOT_MODE InpLotMode     = LOT_RISK_PERCENT; // Lot sizing mode
input double        InpLots        = 0.01;             // Fixed lots
input double        InpRiskPercent = 1.0;              // Risk % per trade
input long          InpMagic       = 990050;           // Magic number

struct Zone
{
   double top;
   double bottom;
};

CTrade   trade;
int      g_emaHandle   = INVALID_HANDLE;
int      g_atrHandle   = INVALID_HANDLE;
double   g_pip         = 0.0;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskReward <= 0.0 || InpEMAPeriod <= 0 || InpZoneLookback <= 0 || InpVolumePeriod <= 0)
   {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_emaHandle = iMA(_Symbol, InpHTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   if(g_emaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (digits == 3 || digits == 5) ? _Point * 10.0 : _Point;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void AddZone(Zone &zones[], double top, double bottom, int createdShift,
             const MqlRates &r[], bool bullish)
{
   if(top <= bottom)
      return;

   if(InpRemoveMitigated)
   {
      for(int k = createdShift - 1; k >= 1; k--)
      {
         if((bullish && r[k].close < bottom) || (!bullish && r[k].close > top))
            return;
      }
   }

   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz].top    = top;
   zones[sz].bottom = bottom;
}

//+------------------------------------------------------------------+
//| Collect HTF order blocks / FVGs from completed bars only.        |
//+------------------------------------------------------------------+
int CollectZones(bool bullish, Zone &zones[])
{
   ArrayResize(zones, 0);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, InpHTF, 0, InpZoneLookback + 3, r);
   if(n < 4)
      return 0;

   bool useOB  = (InpZoneMode != ZONE_FVG_ONLY);
   bool useFVG = (InpZoneMode != ZONE_OB_ONLY);

   // i = newest candle of the pattern
   for(int i = 1; i + 2 < n; i++)
   {
      if(useOB)
      {
         // Bullish OB: bearish candle followed by a candle closing above its high
         if(bullish && r[i + 1].close < r[i + 1].open && r[i].close > r[i + 1].high)
            AddZone(zones, r[i + 1].high, r[i + 1].low, i, r, true);
         // Bearish OB: bullish candle followed by a candle closing below its low
         if(!bullish && r[i + 1].close > r[i + 1].open && r[i].close < r[i + 1].low)
            AddZone(zones, r[i + 1].high, r[i + 1].low, i, r, false);
      }

      if(useFVG)
      {
         if(bullish && r[i].low > r[i + 2].high)
            AddZone(zones, r[i].low, r[i + 2].high, i, r, true);
         if(!bullish && r[i].high < r[i + 2].low)
            AddZone(zones, r[i + 2].low, r[i].high, i, r, false);
      }
   }
   return ArraySize(zones);
}

//+------------------------------------------------------------------+
bool PatternInZone(bool bullish, double low, double high)
{
   Zone zones[];
   int cnt = CollectZones(bullish, zones);
   for(int j = 0; j < cnt; j++)
   {
      if(low <= zones[j].top && high >= zones[j].bottom)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Engulfing candle (shift 1) tick volume vs. average of prior bars |
//+------------------------------------------------------------------+
bool VolumeAboveAverage(long volume)
{
   if(!InpUseVolumeFilter)
      return true;

   long vols[];
   if(CopyTickVolume(_Symbol, InpSignalTF, 2, InpVolumePeriod, vols) != InpVolumePeriod)
      return false;

   double sum = 0.0;
   for(int i = 0; i < InpVolumePeriod; i++)
      sum += (double)vols[i];

   return (double)volume > sum / InpVolumePeriod;
}

//+------------------------------------------------------------------+
//| s[0] = engulfing candle, s[1] = engulfed candle                  |
//+------------------------------------------------------------------+
double CalcSL(bool isBuy, double entry, const MqlRates &s[])
{
   double atr = 0.0;
   if(InpSLMode != SL_CANDLE)
   {
      double a[1];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, a) != 1)
         return 0.0;
      atr = a[0] * InpATRMult;
   }

   if(InpSLMode == SL_ATR)
      return isBuy ? entry - atr : entry + atr;

   double ext = isBuy ? s[1].low : s[1].high;
   if(InpSLUsePattern)
      ext = isBuy ? MathMin(s[0].low, s[1].low) : MathMax(s[0].high, s[1].high);

   double extra = InpSLBufferPips * g_pip + (InpSLMode == SL_CANDLE_PLUS_ATR ? atr : 0.0);
   return isBuy ? ext - extra : ext + extra;
}

//+------------------------------------------------------------------+
double CalcLots(bool isBuy, double price, double sl)
{
   double lots = InpLots;

   if(InpLotMode == LOT_RISK_PERCENT)
   {
      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, price, sl, lossPerLot)
         || lossPerLot >= 0.0)
      {
         Print("Lot calculation failed for price ", price, " sl ", sl);
         return 0.0;
      }
      lots = riskMoney / -lossPerLot;
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minV)
   {
      Print("Calculated lots ", lots, " below minimum ", minV, " - trade skipped");
      return 0.0;
   }
   lots = MathMin(lots, maxV);

   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
}

//+------------------------------------------------------------------+
void OpenTrade(bool isBuy, const MqlRates &s[])
{
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = CalcSL(isBuy, entry, s);
   if(sl <= 0.0)
      return;
   sl = NormalizePrice(sl);

   double risk    = isBuy ? entry - sl : sl - entry;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(risk <= minDist)
   {
      Print((isBuy ? "Buy" : "Sell"), " skipped: SL ", sl, " invalid for entry ", entry);
      return;
   }

   double tp   = NormalizePrice(isBuy ? entry + InpRiskReward * risk
                                      : entry - InpRiskReward * risk);
   double lots = CalcLots(isBuy, entry, sl);
   if(lots <= 0.0)
      return;

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "EMA Zone Engulf Buy")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "EMA Zone Engulf Sell");
   if(!ok)
      Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageBreakeven()
{
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double offset  = InpBEOffsetPips * g_pip;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl <= 0.0)
         continue;

      // SL already at or beyond entry means BE was applied
      double risk = isBuy ? open - sl : sl - open;
      if(risk <= 0.0)
         continue;

      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit = isBuy ? price - open : open - price;
      if(profit < InpBETriggerRR * risk)
         continue;

      double newSL = NormalizePrice(isBuy ? open + offset : open - offset);
      if((isBuy && price - newSL <= minDist) || (!isBuy && newSL - price <= minDist))
         continue;

      if(!trade.PositionModify(ticket, newSL, tp))
         Print("Breakeven modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(InpUseBreakeven)
      ManageBreakeven();

   datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   if(InpOnePosition && HasOpenPosition())
      return;

   MqlRates s[];
   ArraySetAsSeries(s, true);
   if(CopyRates(_Symbol, InpSignalTF, 1, 2, s) != 2)
      return;

   double ema[1];
   if(CopyBuffer(g_emaHandle, 0, 0, 1, ema) != 1)
      return;

   double patLow  = MathMin(s[0].low, s[1].low);
   double patHigh = MathMax(s[0].high, s[1].high);

   bool bullEngulf = s[1].close < s[1].open && s[0].close > s[0].open &&
                     s[0].close > s[1].open && s[0].open <= s[1].close;
   bool bearEngulf = s[1].close > s[1].open && s[0].close < s[0].open &&
                     s[0].close < s[1].open && s[0].open >= s[1].close;

   if(!(bullEngulf || bearEngulf) || !VolumeAboveAverage(s[0].tick_volume))
      return;

   if(InpEnableBuy && bullEngulf && s[0].close > ema[0] && PatternInZone(true, patLow, patHigh))
      OpenTrade(true, s);
   else if(InpEnableSell && bearEngulf && s[0].close < ema[0] && PatternInZone(false, patLow, patHigh))
      OpenTrade(false, s);
}
//+------------------------------------------------------------------+
