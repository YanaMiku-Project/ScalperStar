#property copyright "YanaMiku"
#property link      "https://github.com/YanaMiku-BOTz"
#property version   "1.00"
#property description "Grid Pending Order Scalper (Buy Stop & Sell Stop)"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade         trade;
CSymbolInfo    symInfo;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

input group "=== LOT SIZE ==="
input double InitialLot = 0.01;
input bool UseLotMultiplier = false;
input double LotMultiplier = 1.0;

input group "=== GRID CONFIGURATION ==="
input int GridStepPoints = 100;
input int BuyStopLevels = 5;
input int SellStopLevels = 5;
input bool RebuildGrid = true;
input int PriceTolerancePoints = 5; 

input group "=== SL & TP ==="
input int StopLossPoints = 100;
input int TakeProfitPoints = 0;

input group "=== TRAILING STOP ==="
input bool UseTrailingStop = false;
input int TrailingStartPoints = 200;
input int TrailingStopPoints = 100;
input int TrailingStepPoints = 20;

input group "=== BREAK EVEN ==="
input bool UseBreakEven = false;
input int BreakEvenStartPoints = 200;
input int BreakEvenOffsetPoints = 10;

input group "=== LIMITS & RISK PROTECTION ==="
input int MaxBuyPositions = 10;
input int MaxSellPositions = 10;
input int MaxTotalPositions = 20;
input int MaxPendingOrders = 20;
input int MaxSpreadPoints = 100;
input bool UseDrawdownProtection = true;
input double MaxDrawdownPercent = 20.0;
input bool CloseAllOnMaxDrawdown = false;
input bool UseDailyLossLimit = false;
input double DailyLossLimit = 100.0;

input group "=== TRADING SESSION ==="
input bool UseTradingTime = false;
input int StartHour = 0;
input int StartMinute = 0;
input int EndHour = 23;
input int EndMinute = 59;

input group "=== MISC ==="
input bool UseNewsFilter = false; 
input long MagicNumber = 20260919;

bool bGridUpdateNeeded = true;
double dStartOfDayBalance = 0.0;
datetime dtCurrentDay = 0;
bool bTradingStoppedForDay = false;

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   if(!symInfo.Name(_Symbol)) return INIT_FAILED;
   
   dtCurrentDay = iTime(_Symbol, PERIOD_D1, 0);
   dStartOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick()
  {
   symInfo.Refresh();
   symInfo.RefreshRates();

   UpdateDashboard();
   
   CheckDailyLoss();
   CheckDrawdown();

   if(UseBreakEven) ManageBreakEven();
   if(UseTrailingStop) ManageTrailingStop();

   if(bGridUpdateNeeded || RebuildGrid)
     {
      MaintainGrid();
      bGridUpdateNeeded = false;
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || 
      trans.type == TRADE_TRANSACTION_ORDER_DELETE || 
      trans.type == TRADE_TRANSACTION_HISTORY_ADD)
     {
      bGridUpdateNeeded = true; 
     }
  }

void MaintainGrid()
  {
   if(bTradingStoppedForDay) return;
   if(CheckSpread() > MaxSpreadPoints) return;
   if(!CheckTradingSession()) return;
   
   int totalPos = CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL);
   if(totalPos >= MaxTotalPositions) return;

   int totalPending = CountPendingOrders(ORDER_TYPE_BUY_STOP) + CountPendingOrders(ORDER_TYPE_SELL_STOP);
   if(totalPending >= MaxPendingOrders) return;

   MaintainBuyGrid();
   MaintainSellGrid();
  }

void MaintainBuyGrid()
  {
   int currentBuyStops = CountPendingOrders(ORDER_TYPE_BUY_STOP);
   int currentBuyPos = CountPositions(POSITION_TYPE_BUY);
   
   if(currentBuyPos >= MaxBuyPositions) return;
   
   int neededStops = BuyStopLevels - currentBuyStops;
   if(neededStops <= 0) return;
   
   double ask = symInfo.Ask();
   double step = GridStepPoints * symInfo.Point();
   int added = 0;
   
   for(int i = 1; i <= BuyStopLevels; i++)
     {
      double targetPrice = NormalizePrice(ask + i * step);
      
      if(!PendingExists(ORDER_TYPE_BUY_STOP, targetPrice) && !PositionExists(POSITION_TYPE_BUY, targetPrice))
        {
         double lot = CalculateLotSize(POSITION_TYPE_BUY);
         double sl = (StopLossPoints > 0) ? NormalizePrice(targetPrice - StopLossPoints * symInfo.Point()) : 0;
         double tp = (TakeProfitPoints > 0) ? NormalizePrice(targetPrice + TakeProfitPoints * symInfo.Point()) : 0;
         
         if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, targetPrice, lot, sl, tp, "YANAMIKU GRID BUY"))
           {
            added++;
            if(added >= neededStops) break;
           }
        }
     }
  }

void MaintainSellGrid()
  {
   int currentSellStops = CountPendingOrders(ORDER_TYPE_SELL_STOP);
   int currentSellPos = CountPositions(POSITION_TYPE_SELL);
   
   if(currentSellPos >= MaxSellPositions) return;
   
   int neededStops = SellStopLevels - currentSellStops;
   if(neededStops <= 0) return;
   
   double bid = symInfo.Bid();
   double step = GridStepPoints * symInfo.Point();
   int added = 0;
   
   for(int i = 1; i <= SellStopLevels; i++)
     {
      double targetPrice = NormalizePrice(bid - i * step);
      
      if(!PendingExists(ORDER_TYPE_SELL_STOP, targetPrice) && !PositionExists(POSITION_TYPE_SELL, targetPrice))
        {
         double lot = CalculateLotSize(POSITION_TYPE_SELL);
         double sl = (StopLossPoints > 0) ? NormalizePrice(targetPrice + StopLossPoints * symInfo.Point()) : 0;
         double tp = (TakeProfitPoints > 0) ? NormalizePrice(targetPrice - TakeProfitPoints * symInfo.Point()) : 0;
         
         if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, targetPrice, lot, sl, tp, "YANAMIKU GRID SELL"))
           {
            added++;
            if(added >= neededStops) break;
           }
        }
     }
  }

bool PlacePendingOrder(ENUM_ORDER_TYPE type, double price, double lot, double sl, double tp, string comment)
  {
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLimit = stopsLevel * symInfo.Point();
   
   if(type == ORDER_TYPE_BUY_STOP && (price - symInfo.Ask()) < stopLimit)
      price = symInfo.Ask() + stopLimit;
   if(type == ORDER_TYPE_SELL_STOP && (symInfo.Bid() - price) < stopLimit)
      price = symInfo.Bid() - stopLimit;

   price = NormalizePrice(price);
   lot = NormalizeLot(lot);
   
   if(!trade.OrderOpen(_Symbol, type, lot, 0.0, price, sl, tp, ORDER_TIME_GTC, 0, comment))
     {
      PrintFormat("ORDER FAILED | Type: %s | Price: %.5f | Lot: %.2f | Retcode: %d | Reason: %s", 
                  EnumToString(type), price, lot, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }
   return true;
  }

int CountPendingOrders(ENUM_ORDER_TYPE type)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(ordInfo.SelectByIndex(i))
         if(ordInfo.Symbol() == _Symbol && ordInfo.Magic() == MagicNumber && ordInfo.OrderType() == type)
            count++;
     }
   return count;
  }

int CountPositions(ENUM_POSITION_TYPE type)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber && posInfo.PositionType() == type)
            count++;
     }
   return count;
  }

bool PendingExists(ENUM_ORDER_TYPE type, double price)
  {
   double tolerance = PriceTolerancePoints * symInfo.Point();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(ordInfo.SelectByIndex(i))
        {
         if(ordInfo.Symbol() == _Symbol && ordInfo.Magic() == MagicNumber && ordInfo.OrderType() == type)
           {
            if(MathAbs(ordInfo.PriceOpen() - price) <= tolerance) return true;
           }
        }
     }
   return false;
  }

bool PositionExists(ENUM_POSITION_TYPE type, double price)
  {
   double tolerance = PriceTolerancePoints * symInfo.Point();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber && posInfo.PositionType() == type)
           {
            if(MathAbs(posInfo.PriceOpen() - price) <= tolerance) return true;
           }
        }
     }
   return false;
  }

void ManageBreakEven()
  {
   double beStart = BreakEvenStartPoints * symInfo.Point();
   double beOffset = BreakEvenOffsetPoints * symInfo.Point();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            double entry = posInfo.PriceOpen();
            double sl = posInfo.StopLoss();
            
            if(posInfo.PositionType() == POSITION_TYPE_BUY)
              {
               if(symInfo.Bid() - entry >= beStart && sl < entry)
                  trade.PositionModify(posInfo.Ticket(), NormalizePrice(entry + beOffset), posInfo.TakeProfit());
              }
            else if(posInfo.PositionType() == POSITION_TYPE_SELL)
              {
               if(entry - symInfo.Ask() >= beStart && (sl > entry || sl == 0))
                  trade.PositionModify(posInfo.Ticket(), NormalizePrice(entry - beOffset), posInfo.TakeProfit());
              }
           }
        }
     }
  }

void ManageTrailingStop()
  {
   double tStart = TrailingStartPoints * symInfo.Point();
   double tStop = TrailingStopPoints * symInfo.Point();
   double tStep = TrailingStepPoints * symInfo.Point();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            double entry = posInfo.PriceOpen();
            double sl = posInfo.StopLoss();
            
            if(posInfo.PositionType() == POSITION_TYPE_BUY)
              {
               if(symInfo.Bid() - entry >= tStart)
                 {
                  double newSL = NormalizePrice(symInfo.Bid() - tStop);
                  if(newSL > sl + tStep || sl == 0)
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                 }
              }
            else if(posInfo.PositionType() == POSITION_TYPE_SELL)
              {
               if(entry - symInfo.Ask() >= tStart)
                 {
                  double newSL = NormalizePrice(symInfo.Ask() + tStop);
                  if(newSL < sl - tStep || sl == 0)
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                 }
              }
           }
        }
     }
  }

double CalculateLotSize(ENUM_POSITION_TYPE type)
  {
   if(!UseLotMultiplier) return NormalizeLot(InitialLot);
   int count = (type == POSITION_TYPE_BUY) ? CountPositions(POSITION_TYPE_BUY) : CountPositions(POSITION_TYPE_SELL);
   double lot = InitialLot * MathPow(LotMultiplier, count);
   return NormalizeLot(lot);
  }

double NormalizePrice(double price)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
  }

double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double cleanLot = MathRound(lot / stepLot) * stepLot;
   if(cleanLot < minLot) cleanLot = minLot;
   if(cleanLot > maxLot) cleanLot = maxLot;
   
   return cleanLot;
  }

int CheckSpread()
  {
   return (int)((symInfo.Ask() - symInfo.Bid()) / symInfo.Point());
  }

bool CheckTradingSession()
  {
   if(!UseTradingTime) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentMin = dt.hour * 60 + dt.min;
   int startMin = StartHour * 60 + StartMinute;
   int endMin = EndHour * 60 + EndMinute;
   
   if(startMin < endMin) return (currentMin >= startMin && currentMin <= endMin);
   else return (currentMin >= startMin || currentMin <= endMin);
  }

void CheckDrawdown()
  {
   if(!UseDrawdownProtection) return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPercent = ((balance - equity) / balance) * 100.0;
   
   if(ddPercent >= MaxDrawdownPercent)
     {
      bTradingStoppedForDay = true;
      if(CloseAllOnMaxDrawdown) CloseAllEAOrders();
     }
  }

void CheckDailyLoss()
  {
   datetime day = iTime(_Symbol, PERIOD_D1, 0);
   if(day != dtCurrentDay)
     {
      dtCurrentDay = day;
      dStartOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      bTradingStoppedForDay = false; 
     }
     
   if(UseDailyLossLimit)
     {
      double loss = dStartOfDayBalance - AccountInfoDouble(ACCOUNT_EQUITY);
      if(loss >= DailyLossLimit) bTradingStoppedForDay = true;
     }
  }

void CloseAllEAOrders()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            trade.PositionClose(posInfo.Ticket());
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(ordInfo.SelectByIndex(i))
         if(ordInfo.Symbol() == _Symbol && ordInfo.Magic() == MagicNumber)
            trade.OrderDelete(ordInfo.Ticket());
     }
  }

void UpdateDashboard()
  {
   double floating = 0;
   double lots = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
        if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
          {
           floating += posInfo.Profit();
           lots += posInfo.Volume();
          }
     }

   double dd = ((AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_EQUITY)) / AccountInfoDouble(ACCOUNT_BALANCE)) * 100.0;
   string status = bTradingStoppedForDay ? "STOPPED (RISK LIMIT)" : "RUNNING";

   string dash = "YanaMiku GRID SCALPER\n"
               + "-----------------------------------\n"
               + "Symbol: " + _Symbol + "\n"
               + "Spread: " + IntegerToString(CheckSpread()) + " points\n"
               + "BUY Positions: " + IntegerToString(CountPositions(POSITION_TYPE_BUY)) + "\n"
               + "SELL Positions: " + IntegerToString(CountPositions(POSITION_TYPE_SELL)) + "\n"
               + "BUY STOP: " + IntegerToString(CountPendingOrders(ORDER_TYPE_BUY_STOP)) + "\n"
               + "SELL STOP: " + IntegerToString(CountPendingOrders(ORDER_TYPE_SELL_STOP)) + "\n"
               + "Total Lots: " + DoubleToString(lots, 2) + "\n"
               + "Floating: $" + DoubleToString(floating, 2) + "\n"
               + "Drawdown: " + DoubleToString((dd < 0 ? 0 : dd), 2) + "%\n"
               + "Status: " + status;
   
   Comment(dash);
  }
