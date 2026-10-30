//+------------------------------------------------------------------+
//|                                              GoldOCOBreakout.mq5 |
//|  XAUUSD OCO breakout EA for MetaTrader 5 (HFM)                    |
//|                                                                  |
//|  Cycle:                                                          |
//|   1. Place a Buy Stop above and a Sell Stop below the reference   |
//|      price (last closing price, or current price).                |
//|   2. When one fills, delete the other (OCO).                      |
//|   3. Manage the trade: initial SL, break-even lock, trailing,     |
//|      optional ladder / partial close, time stop.                  |
//|   4. When the trade closes, start again.                          |
//|                                                                  |
//|  All distances are in "pips" where 1 pip = InpPipSize in price.   |
//|  Default InpPipSize = 1.0, i.e. 1 pip = $1.00 gold move           |
//|  (0.15 lot x 4 pips = $60).                                       |
//+------------------------------------------------------------------+
#property copyright "Yves Developer"
#property version   "1.30"
#property description "Gold OCO breakout: Buy Stop + Sell Stop around last close,"
#property description "break-even lock, trailing stop, time stop, news/spread filters."

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED      = 0, // Fixed lot
   LOT_RISK_MONEY = 1  // Lot from max loss in money
  };

input group "=== General ==="
input long   InpMagic              = 260101; // Magic number
input double InpPipSize            = 1.0;    // 1 pip in price (1.0 = $1 gold move)

input group "=== Lot size ==="
input ENUM_LOT_MODE InpLotMode     = LOT_FIXED; // Lot mode
input double InpFixedLot           = 0.15;   // Fixed lot
input double InpRiskMoney          = 60.0;   // Max loss per trade in money (risk mode)

input group "=== Entry ==="
input double InpEntryOffsetPips    = 0.735;  // Pending distance from reference (pips)
input int    InpMaxRefAgeSec       = 60;     // Use last close as reference if closed within N sec
input int    InpPendingExpiryMin   = 0;      // Re-center pendings after N minutes (0 = never)

input group "=== Stop loss / Take profit ==="
input double InpStopLossPips       = 4.0;    // Initial stop loss (pips)
input double InpTakeProfitPips     = 0.0;    // Take profit (pips, 0 = none, trail only)

input group "=== Break-even lock ==="
input bool   InpUseBreakEven       = true;   // Use break-even lock
input double InpBETriggerPips      = 0.6;    // Profit needed to lock (pips)
input double InpBELockPips         = 0.2;    // Profit locked (pips)

input group "=== Trailing stop ==="
input bool   InpUseTrailing        = true;   // Use trailing stop
input double InpTrailStartPips     = 0.6;    // Start trailing at profit (pips)
input double InpTrailGapPips       = 0.4;    // Distance of SL behind price (pips)
input double InpTrailStepPips      = 0.05;   // Min SL improvement per modify (pips)

input group "=== Profit ladder (optional) ==="
input bool   InpUseLadder          = false;  // Use profit ladder
input double InpLadder1TriggerPips = 1.5;    // Step 1: profit reached (pips)
input double InpLadder1LockPips    = 0.8;    // Step 1: lock (pips)
input double InpLadder2TriggerPips = 3.0;    // Step 2: profit reached (pips)
input double InpLadder2LockPips    = 2.0;    // Step 2: lock (pips)

input group "=== Partial close (optional) ==="
input bool   InpUsePartialClose    = false;  // Use partial close
input double InpPartialTriggerPips = 1.0;    // Close part at profit (pips)
input double InpPartialPercent     = 50.0;   // Percent of volume to close

input group "=== Time stop ==="
input bool   InpUseTimeStop        = false;  // Close if profit not locked in time
input int    InpTimeStopMin        = 10;     // Minutes allowed to reach the lock

input group "=== News filter ==="
input bool   InpUseNewsFilter      = true;   // Pause around high-impact news
input string InpNewsCurrencies     = "USD";  // Currencies, comma separated
input int    InpNewsMinutesBefore  = 15;     // Stop N minutes before news
input int    InpNewsMinutesAfter   = 15;     // Resume N minutes after news
input bool   InpCloseBeforeNews    = true;   // Also close open trade before news
input string InpManualNews         = "";     // Extra news "yyyy.mm.dd hh:mi;..." (server time, works in tester)

input group "=== Risk limits ==="
input double InpMaxSpreadPips      = 0.60;   // Max spread to place orders (pips)
input int    InpMaxLossesPerDay    = 0;      // Stop after N losing trades today (0 = off)
input double InpMaxDailyLoss       = 0.0;    // Stop after losing this much today (0 = off)
input double InpDailyProfitTarget  = 0.0;    // Stop after making this much today (0 = off)
input int    InpCooldownSecAfterLoss = 0;    // Wait N seconds after a loss (0 = re-enter immediately)

input group "=== Display ==="
input bool   InpShowPanel          = true;   // Show stats on chart

struct Stats
  {
   int      trades;
   int      wins;
   int      losses;
   double   grossWin;
   double   grossLoss;
   double   net;
   datetime lastCloseTime;
   double   lastClosePrice;
   datetime lastLossTime;
  };

CTrade   trade;
Stats    gDay;
Stats    gAll;
bool     gStatsDirty     = true;
int      gStatsDay       = -1;
datetime gNews[];
datetime gNewsLoaded     = 0;
datetime gLastPlaceTry   = 0;
ulong    gEntryVolTicket = 0;
double   gEntryVol       = 0.0;
string   gStatus         = "";

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double Pips(const double p) { return p * InpPipSize; }

double TickSize()
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (ts > 0.0) ? ts : _Point;
  }

double NormPrice(const double price)
  {
   double ts = TickSize();
   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
  }

double MinStopDist()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * _Point;
  }

double NormLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return NormalizeDouble(lots, 2);
  }

double CalcLots()
  {
   double lots = InpFixedLot;
   if(InpLotMode == LOT_RISK_MONEY)
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0.0)
         tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double lossPerLot = Pips(InpStopLossPips) / TickSize() * tv;
      if(lossPerLot > 0.0)
         lots = InpRiskMoney / lossPerLot;
     }
   return NormLots(lots);
  }

bool IsWeekend()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 0 || t.day_of_week == 6);
  }

//+------------------------------------------------------------------+
//| News filter                                                      |
//+------------------------------------------------------------------+
void AddNews(const datetime t)
  {
   int n = ArraySize(gNews);
   ArrayResize(gNews, n + 1);
   gNews[n] = t;
  }

void RefreshNews()
  {
   datetime now = TimeCurrent();
   if(gNewsLoaded > 0 && now - gNewsLoaded < 300)
      return;
   gNewsLoaded = now;
   ArrayResize(gNews, 0);

   string items[];
   int n = StringSplit(InpManualNews, ';', items);
   for(int i = 0; i < n; i++)
     {
      string s = items[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "")
         continue;
      datetime d = StringToTime(s);
      if(d > 0)
         AddNews(d);
     }

   // The economic calendar is not available in the Strategy Tester.
   if(MQLInfoInteger(MQL_TESTER))
      return;

   string cur[];
   int nc = StringSplit(InpNewsCurrencies, ',', cur);
   for(int c = 0; c < nc; c++)
     {
      string code = cur[c];
      StringTrimLeft(code);
      StringTrimRight(code);
      if(code == "")
         continue;
      MqlCalendarValue vals[];
      if(CalendarValueHistory(vals, now - 86400, now + 2 * 86400, NULL, code) <= 0)
         continue;
      for(int i = 0; i < ArraySize(vals); i++)
        {
         MqlCalendarEvent ev;
         if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
            AddNews(vals[i].time);
        }
     }
  }

bool NewsBlocked()
  {
   if(!InpUseNewsFilter)
      return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(gNews); i++)
      if(now >= gNews[i] - InpNewsMinutesBefore * 60 && now <= gNews[i] + InpNewsMinutesAfter * 60)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Statistics (per closed position, so partial closes count once)   |
//+------------------------------------------------------------------+
void CollectStats(const datetime from, Stats &s)
  {
   ZeroMemory(s);
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return;

   ulong    ids[];
   double   pnl[];
   datetime closeT[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;

      ulong pid = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < ArraySize(ids); j++)
         if(ids[j] == pid)
           {
            k = j;
            break;
           }
      if(k < 0)
        {
         k = ArraySize(ids);
         ArrayResize(ids, k + 1);
         ArrayResize(pnl, k + 1);
         ArrayResize(closeT, k + 1);
         ids[k] = pid;
         pnl[k] = 0.0;
         closeT[k] = 0;
        }

      pnl[k] += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
                + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);

      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
        {
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(t >= closeT[k])
            closeT[k] = t;
         if(t >= s.lastCloseTime)
           {
            s.lastCloseTime  = t;
            s.lastClosePrice = HistoryDealGetDouble(d, DEAL_PRICE);
           }
        }
     }

   for(int k = 0; k < ArraySize(ids); k++)
     {
      if(closeT[k] == 0 || PositionSelectByTicket(ids[k]))
         continue; // never closed, or still open after a partial close
      s.trades++;
      s.net += pnl[k];
      if(pnl[k] >= 0.0)
        {
         s.wins++;
         s.grossWin += pnl[k];
        }
      else
        {
         s.losses++;
         s.grossLoss += pnl[k];
         if(closeT[k] > s.lastLossTime)
            s.lastLossTime = closeT[k];
        }
     }
  }

void RefreshStats()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(!gStatsDirty && t.day_of_year == gStatsDay)
      return;
   t.hour = 0;
   t.min  = 0;
   t.sec  = 0;
   CollectStats(StructToTime(t), gDay);
   CollectStats(0, gAll);
   gStatsDay   = t.day_of_year;
   gStatsDirty = false;
  }

bool DailyLimitHit()
  {
   if(InpMaxLossesPerDay > 0 && gDay.losses >= InpMaxLossesPerDay)
      return true;
   if(InpMaxDailyLoss > 0.0 && gDay.net <= -InpMaxDailyLoss)
      return true;
   if(InpDailyProfitTarget > 0.0 && gDay.net >= InpDailyProfitTarget)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Orders and positions                                             |
//+------------------------------------------------------------------+
int GetPositions(ulong &tickets[])
  {
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = t;
     }
   return ArraySize(tickets);
  }

int GetPendings(ulong &tickets[])
  {
   ArrayResize(tickets, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = t;
     }
   return ArraySize(tickets);
  }

void DeleteAllPendings()
  {
   ulong p[];
   int n = GetPendings(p);
   for(int i = 0; i < n; i++)
      trade.OrderDelete(p[i]);
  }

void CloseAllPositions()
  {
   ulong p[];
   int n = GetPositions(p);
   for(int i = 0; i < n; i++)
      trade.PositionClose(p[i]);
  }

// If both pendings filled before the EA could cancel one, keep the first and close the newer.
void CloseNewestPosition(const ulong &tickets[])
  {
   ulong newest = 0;
   long  newestTime = -1;
   for(int i = 0; i < ArraySize(tickets); i++)
      if(PositionSelectByTicket(tickets[i]))
        {
         long t = PositionGetInteger(POSITION_TIME_MSC);
         if(t > newestTime)
           {
            newestTime = t;
            newest = tickets[i];
           }
        }
   if(newest > 0)
     {
      Print("Both pending orders filled; closing newest position #", newest);
      trade.PositionClose(newest);
     }
  }

double EntryVolume(const ulong posTicket)
  {
   if(gEntryVolTicket == posTicket)
      return gEntryVol;
   double vol = 0.0;
   if(HistorySelectByPosition(posTicket))
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d > 0 && HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
            vol += HistoryDealGetDouble(d, DEAL_VOLUME);
        }
   gEntryVolTicket = posTicket;
   gEntryVol = vol;
   gStatsDirty = true; // HistorySelectByPosition replaced the history selection
   return vol;
  }

//+------------------------------------------------------------------+
//| Place the Buy Stop / Sell Stop pair                              |
//+------------------------------------------------------------------+
void PlacePair()
  {
   if(TimeCurrent() - gLastPlaceTry < 3)
      return;
   gLastPlaceTry = TimeCurrent();

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;

   double mid  = (tk.ask + tk.bid) / 2.0;
   double ref  = mid;
   if(gDay.lastCloseTime > 0 && TimeCurrent() - gDay.lastCloseTime <= InpMaxRefAgeSec)
      ref = gDay.lastClosePrice;

   double off  = Pips(InpEntryOffsetPips);
   double minD = MinStopDist();
   double buy  = NormPrice(ref + off);
   double sell = NormPrice(ref - off);

   // Last close too far from current price: fall back to current price.
   if(buy - tk.ask <= minD || tk.bid - sell <= minD)
     {
      ref  = mid;
      buy  = NormPrice(ref + off);
      sell = NormPrice(ref - off);
     }
   // Offset smaller than spread / broker minimum: push orders out to the nearest valid price.
   if(buy - tk.ask <= minD)
      buy = NormPrice(tk.ask + minD + TickSize());
   if(tk.bid - sell <= minD)
      sell = NormPrice(tk.bid - minD - TickSize());

   double sl   = Pips(InpStopLossPips);
   double tp   = Pips(InpTakeProfitPips);
   double lots = CalcLots();

   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   if((SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_GTC) == 0)
      tt = ORDER_TIME_DAY;

   bool okBuy = trade.BuyStop(lots, buy, _Symbol, NormPrice(buy - sl),
                              tp > 0.0 ? NormPrice(buy + tp) : 0.0, tt, 0, "OCO buy");
   if(!okBuy)
     {
      Print("BuyStop failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
     }
   bool okSell = trade.SellStop(lots, sell, _Symbol, NormPrice(sell + sl),
                                tp > 0.0 ? NormPrice(sell - tp) : 0.0, tt, 0, "OCO sell");
   if(!okSell)
     {
      Print("SellStop failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      DeleteAllPendings();
      return;
     }
   PrintFormat("Placed pair around %.3f: BuyStop %.3f / SellStop %.3f, lots %.2f",
               ref, buy, sell, lots);
  }

void ManagePendings(const ulong &tickets[], const bool keep)
  {
   int n = ArraySize(tickets);
   if(!keep || n == 1) // filters closed, or one leg missing: remove and re-place later
     {
      DeleteAllPendings();
      return;
     }
   if(InpPendingExpiryMin <= 0)
      return;
   for(int i = 0; i < n; i++)
      if(OrderSelect(tickets[i]) &&
         TimeCurrent() - (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= InpPendingExpiryMin * 60)
        {
         DeleteAllPendings();
         return;
        }
  }

//+------------------------------------------------------------------+
//| Manage the open trade                                            |
//+------------------------------------------------------------------+
void Tighten(const bool isBuy, const double level, double &sl)
  {
   if(isBuy)
     {
      if(sl == 0.0 || level > sl)
         sl = level;
     }
   else
     {
      if(sl == 0.0 || level < sl)
         sl = level;
     }
  }

void ManagePosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;

   bool     isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double   sl     = PositionGetDouble(POSITION_SL);
   double   tp     = PositionGetDouble(POSITION_TP);
   double   vol    = PositionGetDouble(POSITION_VOLUME);
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

   double price  = isBuy ? tk.bid : tk.ask; // price the position would close at
   double profit = isBuy ? price - open : open - price;
   bool   locked = isBuy ? (sl > 0.0 && sl >= open) : (sl > 0.0 && sl <= open);

   // Time stop: trade never reached the lock in time.
   if(InpUseTimeStop && !locked && TimeCurrent() - opened >= InpTimeStopMin * 60)
     {
      Print("Time stop: closing #", ticket);
      trade.PositionClose(ticket);
      return;
     }

   // Partial close once.
   if(InpUsePartialClose && profit >= Pips(InpPartialTriggerPips) && vol >= EntryVolume(ticket) - 1e-8)
     {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double cv   = NormalizeDouble(MathFloor(vol * InpPartialPercent / 100.0 / step + 1e-9) * step, 2);
      if(cv >= vmin && vol - cv >= vmin - 1e-8)
        {
         trade.PositionClosePartial(ticket, cv);
         return;
        }
     }

   double newSL = sl;
   if(InpUseBreakEven && profit >= Pips(InpBETriggerPips))
      Tighten(isBuy, isBuy ? open + Pips(InpBELockPips) : open - Pips(InpBELockPips), newSL);
   if(InpUseLadder && profit >= Pips(InpLadder1TriggerPips))
      Tighten(isBuy, isBuy ? open + Pips(InpLadder1LockPips) : open - Pips(InpLadder1LockPips), newSL);
   if(InpUseLadder && profit >= Pips(InpLadder2TriggerPips))
      Tighten(isBuy, isBuy ? open + Pips(InpLadder2LockPips) : open - Pips(InpLadder2LockPips), newSL);
   if(InpUseTrailing && profit >= Pips(InpTrailStartPips))
      Tighten(isBuy, isBuy ? price - Pips(InpTrailGapPips) : price + Pips(InpTrailGapPips), newSL);

   if(newSL == sl)
      return;

   // Respect broker stop/freeze level.
   double minD = MinStopDist();
   if(isBuy && price - newSL <= minD)
      newSL = price - minD - TickSize();
   if(!isBuy && newSL - price <= minD)
      newSL = price + minD + TickSize();
   newSL = NormPrice(newSL);

   double step = Pips(InpTrailStepPips) - 1e-9;
   bool better = isBuy ? (sl == 0.0 || newSL - sl >= step) : (sl == 0.0 || sl - newSL >= step);
   if(!better)
      return;

   if(!trade.PositionModify(ticket, newSL, tp))
      Print("Modify SL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
string StatsLine(const string name, const Stats &s)
  {
   double wr     = s.trades > 0 ? 100.0 * s.wins / s.trades : 0.0;
   double avgWin = s.wins > 0 ? s.grossWin / s.wins : 0.0;
   double avgLos = s.losses > 0 ? s.grossLoss / s.losses : 0.0;
   return StringFormat("%s: trades %d | wins %d | losses %d | win rate %.1f%% | avg win %.2f | avg loss %.2f | net %.2f",
                       name, s.trades, s.wins, s.losses, wr, avgWin, avgLos, s.net);
  }

void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   Comment("Gold OCO Breakout v1.3  |  ", _Symbol, "  |  lots ", DoubleToString(CalcLots(), 2),
           "  |  spread ", DoubleToString((tk.ask - tk.bid) / InpPipSize, 3), " pips\n",
           "Status: ", gStatus, "\n",
           StatsLine("Today", gDay), "\n",
           StatsLine("All  ", gAll));
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("Warning: this EA is designed for gold (XAUUSD). Current symbol: ", _Symbol);

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double perPip = InpPipSize / TickSize() * tv * CalcLots();
   PrintFormat("%s: digits %d, tick %.5f, stops level %d pts, freeze %d pts, lots %.2f, money per pip %.2f, SL money %.2f",
               _Symbol, _Digits, TickSize(),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
               CalcLots(), perPip, perPip * InpStopLossPips);
   if(Pips(InpTrailGapPips) <= MinStopDist())
      Print("Warning: trailing gap is not above the broker stop level; SL will be kept at the minimum distance.");

   gStatsDirty = true;
   gNewsLoaded = 0;
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   gStatsDirty = true;
   RefreshStats();
   Print(StatsLine("All", gAll));
   Comment("");
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   gStatsDirty = true;
   // OCO: as soon as one pending fills, cancel the other.
   if(HistoryDealSelect(trans.deal) &&
      HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagic &&
      HistoryDealGetString(trans.deal, DEAL_SYMBOL) == _Symbol &&
      HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
      DeleteAllPendings();
  }

void OnTick()
  {
   RefreshStats();
   RefreshNews();

   bool news    = NewsBlocked();
   bool weekend = IsWeekend();

   ulong pos[], pend[];
   int np = GetPositions(pos);
   int nq = GetPendings(pend);

   if(np > 0)
     {
      if(nq > 0)
         DeleteAllPendings();
      if(np >= 2)
        {
         CloseNewestPosition(pos);
         gStatus = "Both orders filled - closed one";
        }
      else if(news && InpCloseBeforeNews)
        {
         CloseAllPositions();
         gStatus = "News - closed trade";
        }
      else
        {
         ManagePosition(pos[0]);
         gStatus = "Managing trade";
        }
      UpdatePanel();
      return;
     }

   bool limit = DailyLimitHit();
   bool keep  = !weekend && !news && !limit;

   if(nq > 0)
     {
      ManagePendings(pend, keep);
      gStatus = keep ? "Pending orders waiting" : "Filters closed - removed pendings";
      UpdatePanel();
      return;
     }

   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   bool spreadOk = (tk.ask - tk.bid) <= Pips(InpMaxSpreadPips);
   bool cooldown = gDay.lastLossTime > 0 && TimeCurrent() - gDay.lastLossTime < InpCooldownSecAfterLoss;

   if(weekend)
      gStatus = "Weekend - market closed";
   else if(news)
      gStatus = "News pause";
   else if(limit)
      gStatus = "Daily limit reached - done for today";
   else if(cooldown)
      gStatus = "Cooldown after loss";
   else if(!spreadOk)
      gStatus = "Spread too wide";
   else
     {
      gStatus = "Placing orders";
      PlacePair();
     }
   UpdatePanel();
  }
//+------------------------------------------------------------------+
