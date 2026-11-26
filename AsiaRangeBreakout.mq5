//+------------------------------------------------------------------+
//|                                       AsiaRangeBreakout_EA.mq5   |
//|  Buy stop at Asia high, sell stop at Asia low.                   |
//|  SL on the opposite side of the range, TP = RR multiple.         |
//+------------------------------------------------------------------+
#property version   "1.00"

#include <Trade/Trade.mqh>

input group "=== Asia Session (server time) ==="
input int    AsiaStartHour   = 0;    // Session start hour
input int    AsiaStartMinute = 0;    // Session start minute
input int    AsiaEndHour     = 7;    // Session end hour
input int    AsiaEndMinute   = 0;    // Session end minute
input int    CancelHour      = 20;   // Delete unfilled stop orders at this hour
input int    CancelMinute    = 0;    // Delete unfilled stop orders at this minute

input group "=== Risk ==="
input double RiskPercent     = 0.5;  // Risk per trade (% of balance)
input double TP_RR           = 2.0;  // Take profit as multiple of risk

input group "=== Filters ==="
input bool   UseEMAFilter    = false; // Only trade in the direction of the daily EMA
input int    EMAPeriod       = 50;    // Daily EMA period
input bool   OneCancelsOther = true;  // Delete the opposite stop order once one is filled

input group "=== Break-Even ==="
input bool   UseBreakEven    = false; // Move SL to entry after reaching trigger R
input double BreakEvenAtR    = 1.0;   // R multiple that triggers break-even

input group "=== Market Close ==="
input bool   CloseTradesBeforeClose = false; // Close all open trades before market close
input int    MinutesBeforeClose     = 15;    // Minutes before market close to close trades

input group "=== Trade Settings ==="
input int    MagicNumber     = 202611;
input string TradeComment    = "AsiaBreakout";

CTrade   Trade;
int      EMAHandle    = INVALID_HANDLE;
datetime LastSetupDay = 0;

//-------------------------------------------------------------------
datetime DayStart(datetime t) { return t - (t % 86400); }

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double StopsDistance()
{
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
}

bool IsOwn(string symbol, long magic) { return symbol == _Symbol && magic == MagicNumber; }

//--- Lot size so that hitting the SL loses RiskPercent of balance; 0 if below min lot
double CalcLots(double slDistance)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0 || lotStep <= 0) return 0;

   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double lossPerLot = (slDistance / tickSize) * tickValue;
   double lots       = MathFloor(riskMoney / lossPerLot / lotStep + 1e-8) * lotStep;

   if(lots < minLot)
   {
      PrintFormat("Lot size %.4f below minimum %.2f for risk %.2f%% – order skipped.", lots, minLot, RiskPercent);
      return 0;
   }
   return MathMin(lots, maxLot);
}

//--- True if this EA already set up orders today (also survives EA restarts)
bool SetupExistsToday(datetime today)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !IsOwn(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC))) continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) >= today) return true;
   }
   if(!HistorySelect(today, TimeCurrent() + 60)) return false;
   for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryOrderGetTicket(i);
      if(t == 0) continue;
      if(IsOwn(HistoryOrderGetString(t, ORDER_SYMBOL), HistoryOrderGetInteger(t, ORDER_MAGIC))) return true;
   }
   return false;
}

void DeletePendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !IsOwn(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC))) continue;
      if(Trade.OrderDelete(t))
         Print("Pending order #", t, " deleted.");
   }
}

//--- Delete remaining stop orders once a position from today's setup is open
void ApplyOCO(datetime today)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOwn(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC))) continue;
      if((datetime)PositionGetInteger(POSITION_TIME) >= today)
      {
         DeletePendings();
         return;
      }
   }
}

//--- True if within MinutesBeforeClose of the symbol's trade session end
bool IsNearMarketClose()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   long secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime from, to;

   for(uint i = 0; SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to); i++)
   {
      if(secOfDay < (long)from || secOfDay >= (long)to) continue;

      long closeAt = (long)to;
      // A session ending at 24:00 that resumes at 00:00 the next day is not a real close
      for(int d = 1; d < 7 && closeAt % 86400 == 0; d++)
      {
         datetime nf, nt;
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)((dt.day_of_week + d) % 7), 0, nf, nt) || nf != 0)
            break;
         closeAt = d * 86400L + (long)nt;
      }
      return closeAt - secOfDay <= MinutesBeforeClose * 60L;
   }
   return false;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOwn(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC))) continue;
      if(Trade.PositionClose(t))
         Print("Market close: position #", t, " closed.");
      else
         Print("Market close: failed to close #", t, ": ", Trade.ResultRetcodeDescription());
   }
}

void ManageBreakEven()
{
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = StopsDistance();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOwn(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC))) continue;

      double entry = NormalizePrice(PositionGetDouble(POSITION_PRICE_OPEN));
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl <= 0) continue;

      // SL still behind entry means break-even has not been applied yet
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double risk = entry - sl;
         if(risk > 0 && bid - entry >= risk * BreakEvenAtR && bid - entry > minDist)
            if(Trade.PositionModify(t, entry, tp))
               Print("Break-even: BUY #", t, " SL moved to ", entry);
      }
      else
      {
         double risk = sl - entry;
         if(risk > 0 && entry - ask >= risk * BreakEvenAtR && entry - ask > minDist)
            if(Trade.PositionModify(t, entry, tp))
               Print("Break-even: SELL #", t, " SL moved to ", entry);
      }
   }
}

void PlaceStop(bool isBuy, double price, double sl, double tp)
{
   price = NormalizePrice(price);
   sl    = NormalizePrice(sl);
   tp    = NormalizePrice(tp);

   double lots = CalcLots(MathAbs(price - sl));
   if(lots <= 0) return;

   bool ok = isBuy ? Trade.BuyStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment)
                   : Trade.SellStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment);
   if(!ok)
      Print(isBuy ? "BuyStop" : "SellStop", " failed: ", Trade.ResultRetcodeDescription());
}

//--- Returns false if data is not ready yet so the setup is retried on the next tick
bool PlaceBreakoutOrders(datetime sessStart, datetime sessEnd)
{
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, sessStart, sessEnd - 1, r);
   if(n <= 0) return false;

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < n; i++)
   {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
   }
   double range = hi - lo;
   if(range <= 0) return true;

   bool allowLong = true, allowShort = true;
   if(UseEMAFilter)
   {
      double ema[1];
      if(CopyBuffer(EMAHandle, 0, 1, 1, ema) != 1) return false;
      double prevClose = iClose(_Symbol, PERIOD_D1, 1);
      if(prevClose <= 0) return false;
      allowLong  = prevClose > ema[0];
      allowShort = prevClose < ema[0];
   }

   PrintFormat("Asia range %s: high=%s low=%s", TimeToString(sessEnd, TIME_DATE),
               DoubleToString(hi, _Digits), DoubleToString(lo, _Digits));

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = StopsDistance();

   if(allowLong)
   {
      if(hi - ask > minDist) PlaceStop(true, hi, lo, hi + range * TP_RR);
      else Print("Price already above/near Asia high – buy stop skipped.");
   }
   if(allowShort)
   {
      if(bid - lo > minDist) PlaceStop(false, lo, hi, lo - range * TP_RR);
      else Print("Price already below/near Asia low – sell stop skipped.");
   }
   return true;
}

//-------------------------------------------------------------------
int OnInit()
{
   int endMin    = AsiaEndHour * 60 + AsiaEndMinute;
   int cancelMin = CancelHour * 60 + CancelMinute;
   if(cancelMin <= endMin)
   {
      Print("Cancel time must be after the Asia session end.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(RiskPercent <= 0 || TP_RR <= 0 || BreakEvenAtR <= 0)
   {
      Print("RiskPercent, TP_RR and BreakEvenAtR must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseEMAFilter)
   {
      EMAHandle = iMA(_Symbol, PERIOD_D1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(EMAHandle == INVALID_HANDLE)
      {
         Print("Failed to create daily EMA handle.");
         return INIT_FAILED;
      }
   }

   Trade.SetExpertMagicNumber(MagicNumber);

   datetime today = DayStart(TimeCurrent());
   if(SetupExistsToday(today)) LastSetupDay = today;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(EMAHandle != INVALID_HANDLE) IndicatorRelease(EMAHandle);
}

void OnTick()
{
   datetime now       = TimeCurrent();
   datetime today     = DayStart(now);
   datetime sessEnd   = today + AsiaEndHour * 3600 + AsiaEndMinute * 60;
   datetime sessStart = today + AsiaStartHour * 3600 + AsiaStartMinute * 60;
   if(sessStart >= sessEnd) sessStart -= 86400; // session starts on the previous day
   datetime cancelAt  = today + CancelHour * 3600 + CancelMinute * 60;

   if(CloseTradesBeforeClose && IsNearMarketClose()) CloseAllPositions();
   if(OneCancelsOther) ApplyOCO(today);
   if(UseBreakEven)    ManageBreakEven();

   if(now >= cancelAt)
   {
      DeletePendings();
      return;
   }
   if(now < sessEnd || LastSetupDay == today) return;

   if(PlaceBreakoutOrders(sessStart, sessEnd))
      LastSetupDay = today;
}
//+------------------------------------------------------------------+
