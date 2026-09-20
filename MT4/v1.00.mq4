#property copyright "YanaMiku"
#property link      "https://github.com/YanaMiku-BOTz"
#property version   "1.00"
#property strict

input double InitialLot = 0.01;
input bool UseLotMultiplier = false;
input double LotMultiplier = 1.0;

input int GridStepPoints = 100;
input int BuyStopLevels = 5;
input int SellStopLevels = 5;
input bool RebuildGrid = true;
input int PriceTolerancePoints = 5; 

input int StopLossPoints = 100;
input int TakeProfitPoints = 0;

input bool UseTrailingStop = false;
input int TrailingStartPoints = 200;
input int TrailingStopPoints = 100;
input int TrailingStepPoints = 20;

input bool UseBreakEven = false;
input int BreakEvenStartPoints = 200;
input int BreakEvenOffsetPoints = 10;

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

input bool UseTradingTime = false;
input int StartHour = 0;
input int StartMinute = 0;
input int EndHour = 23;
input int EndMinute = 59;

input bool UseNewsFilter = false; 
input int MagicNumber = 20260919;

bool bGridUpdateNeeded = true;
double dStartOfDayBalance = 0.0;
datetime dtCurrentDay = 0;
bool bTradingStoppedForDay = false;
int lastOrdersTotal = 0;

int OnInit()
  {
   dtCurrentDay = iTime(Symbol(), PERIOD_D1, 0);
   dStartOfDayBalance = AccountBalance();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick()
  {
   int currentOrders = OrdersTotal();
   if(currentOrders != lastOrdersTotal)
     {
      bGridUpdateNeeded = true;
      lastOrdersTotal = currentOrders;
     }

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

void MaintainGrid()
  {
   if(bTradingStoppedForDay) return;
   if(CheckSpread() > MaxSpreadPoints) return;
   if(!CheckTradingSession()) return;
   
   int totalPos = CountOrders(OP_BUY) + CountOrders(OP_SELL);
   if(totalPos >= MaxTotalPositions) return;

   int totalPending = CountOrders(OP_BUYSTOP) + CountOrders(OP_SELLSTOP);
   if(totalPending >= MaxPendingOrders) return;

   MaintainBuyGrid();
   MaintainSellGrid();
  }

void MaintainBuyGrid()
  {
   int currentBuyStops = CountOrders(OP_BUYSTOP);
   int currentBuyPos = CountOrders(OP_BUY);
   
   if(currentBuyPos >= MaxBuyPositions) return;
   
   int neededStops = BuyStopLevels - currentBuyStops;
   if(neededStops <= 0) return;
   
   double step = GridStepPoints * Point;
   int added = 0;
   
   for(int i = 1; i <= BuyStopLevels; i++)
     {
      double targetPrice = NormalizePrice(Ask + i * step);
      
      if(!OrderExists(OP_BUYSTOP, targetPrice) && !OrderExists(OP_BUY, targetPrice))
        {
         double lot = CalculateLotSize(OP_BUY);
         double sl = (StopLossPoints > 0) ? NormalizePrice(targetPrice - StopLossPoints * Point) : 0;
         double tp = (TakeProfitPoints > 0) ? NormalizePrice(targetPrice + TakeProfitPoints * Point) : 0;
         
         if(PlacePendingOrder(OP_BUYSTOP, targetPrice, lot, sl, tp, "YANAMIKU GRID BUY"))
           {
            added++;
            if(added >= neededStops) break;
           }
        }
     }
  }

void MaintainSellGrid()
  {
   int currentSellStops = CountOrders(OP_SELLSTOP);
   int currentSellPos = CountOrders(OP_SELL);
   
   if(currentSellPos >= MaxSellPositions) return;
   
   int neededStops = SellStopLevels - currentSellStops;
   if(neededStops <= 0) return;
   
   double step = GridStepPoints * Point;
   int added = 0;
   
   for(int i = 1; i <= SellStopLevels; i++)
     {
      double targetPrice = NormalizePrice(Bid - i * step);
      
      if(!OrderExists(OP_SELLSTOP, targetPrice) && !OrderExists(OP_SELL, targetPrice))
        {
         double lot = CalculateLotSize(OP_SELL);
         double sl = (StopLossPoints > 0) ? NormalizePrice(targetPrice + StopLossPoints * Point) : 0;
         double tp = (TakeProfitPoints > 0) ? NormalizePrice(targetPrice - TakeProfitPoints * Point) : 0;
         
         if(PlacePendingOrder(OP_SELLSTOP, targetPrice, lot, sl, tp, "YANAMIKU GRID SELL"))
           {
            added++;
            if(added >= neededStops) break;
           }
        }
     }
  }

bool PlacePendingOrder(int type, double price, double lot, double sl, double tp, string commentStr)
  {
   double stopLimit = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   
   if(type == OP_BUYSTOP && (price - Ask) < stopLimit)
      price = Ask + stopLimit;
   if(type == OP_SELLSTOP && (Bid - price) < stopLimit)
      price = Bid - stopLimit;

   price = NormalizePrice(price);
   lot = NormalizeLot(lot);
   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);
   
   int ticket = OrderSend(Symbol(), type, lot, price, 3, sl, tp, commentStr, MagicNumber, 0, clrNONE);
   if(ticket < 0)
     {
      PrintFormat("ORDER FAILED | Type: %d | Price: %.5f | Lot: %.2f | Error: %d", type, price, lot, GetLastError());
      return false;
     }
   return true;
  }

int CountOrders(int type)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == type)
           {
            count++;
           }
        }
     }
   return count;
  }

bool OrderExists(int type, double price)
  {
   double tolerance = PriceTolerancePoints * Point;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == type)
           {
            if(MathAbs(OrderOpenPrice() - price) <= tolerance) return true;
           }
        }
     }
   return false;
  }

void ManageBreakEven()
  {
   double beStart = BreakEvenStartPoints * Point;
   double beOffset = BreakEvenOffsetPoints * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
           {
            double entry = OrderOpenPrice();
            double sl = OrderStopLoss();
            double tp = OrderTakeProfit();
            
            if(OrderType() == OP_BUY)
              {
               if(Bid - entry >= beStart && (sl < entry || sl == 0))
                 {
                  if(OrderModify(OrderTicket(), entry, NormalizePrice(entry + beOffset), tp, 0, clrNONE)) {}
                 }
              }
            else if(OrderType() == OP_SELL)
              {
               if(entry - Ask >= beStart && (sl > entry || sl == 0))
                 {
                  if(OrderModify(OrderTicket(), entry, NormalizePrice(entry - beOffset), tp, 0, clrNONE)) {}
                 }
              }
           }
        }
     }
  }

void ManageTrailingStop()
  {
   double tStart = TrailingStartPoints * Point;
   double tStop = TrailingStopPoints * Point;
   double tStep = TrailingStepPoints * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
           {
            double entry = OrderOpenPrice();
            double sl = OrderStopLoss();
            double tp = OrderTakeProfit();
            
            if(OrderType() == OP_BUY)
              {
               if(Bid - entry >= tStart)
                 {
                  double newSL = NormalizePrice(Bid - tStop);
                  if(newSL > sl + tStep || sl == 0)
                    {
                     if(OrderModify(OrderTicket(), entry, newSL, tp, 0, clrNONE)) {}
                    }
                 }
              }
            else if(OrderType() == OP_SELL)
              {
               if(entry - Ask >= tStart)
                 {
                  double newSL = NormalizePrice(Ask + tStop);
                  if(newSL < sl - tStep || sl == 0)
                    {
                     if(OrderModify(OrderTicket(), entry, newSL, tp, 0, clrNONE)) {}
                    }
                 }
              }
           }
        }
     }
  }

double CalculateLotSize(int type)
  {
   if(!UseLotMultiplier) return NormalizeLot(InitialLot);
   int count = CountOrders(type);
   double lot = InitialLot * MathPow(LotMultiplier, count);
   return NormalizeLot(lot);
  }

double NormalizePrice(double price)
  {
   return NormalizeDouble(price, Digits);
  }

double NormalizeLot(double lot)
  {
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double stepLot = MarketInfo(Symbol(), MODE_LOTSTEP);
   
   double cleanLot = MathRound(lot / stepLot) * stepLot;
   if(cleanLot < minLot) cleanLot = minLot;
   if(cleanLot > maxLot) cleanLot = maxLot;
   
   return cleanLot;
  }

int CheckSpread()
  {
   return (int)MathRound((Ask - Bid) / Point);
  }

bool CheckTradingSession()
  {
   if(!UseTradingTime) return true;
   int currentMin = Hour() * 60 + Minute();
   int startMin = StartHour * 60 + StartMinute;
   int endMin = EndHour * 60 + EndMinute;
   
   if(startMin < endMin) return (currentMin >= startMin && currentMin <= endMin);
   else return (currentMin >= startMin || currentMin <= endMin);
  }

void CheckDrawdown()
  {
   if(!UseDrawdownProtection) return;
   double equity = AccountEquity();
   double balance = AccountBalance();
   double ddPercent = ((balance - equity) / balance) * 100.0;
   
   if(ddPercent >= MaxDrawdownPercent)
     {
      bTradingStoppedForDay = true;
      if(CloseAllOnMaxDrawdown) CloseAllEAOrders();
     }
  }

void CheckDailyLoss()
  {
   datetime day = iTime(Symbol(), PERIOD_D1, 0);
   if(day != dtCurrentDay)
     {
      dtCurrentDay = day;
      dStartOfDayBalance = AccountBalance();
      bTradingStoppedForDay = false; 
     }
     
   if(UseDailyLossLimit)
     {
      double loss = dStartOfDayBalance - AccountEquity();
      if(loss >= DailyLossLimit) bTradingStoppedForDay = true;
     }
  }

void CloseAllEAOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
           {
            if(OrderType() == OP_BUY)
               if(OrderClose(OrderTicket(), OrderLots(), Bid, 3)) {}
            if(OrderType() == OP_SELL)
               if(OrderClose(OrderTicket(), OrderLots(), Ask, 3)) {}
            if(OrderType() > 1)
               if(OrderDelete(OrderTicket())) {}
           }
        }
     }
  }

void UpdateDashboard()
  {
   double floating = 0;
   double lots = 0;
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
           {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
              {
               floating += OrderProfit() + OrderSwap() + OrderCommission();
               lots += OrderLots();
              }
           }
        }
     }

   double dd = ((AccountBalance() - AccountEquity()) / AccountBalance()) * 100.0;
   string status = bTradingStoppedForDay ? "STOPPED (RISK LIMIT)" : "RUNNING";

   string dash = "YanaMiku GRID SCALPER (MT4)\n"
               + "-----------------------------------\n"
               + "Symbol: " + Symbol() + "\n"
               + "Spread: " + IntegerToString(CheckSpread()) + " points\n"
               + "BUY Positions: " + IntegerToString(CountOrders(OP_BUY)) + "\n"
               + "SELL Positions: " + IntegerToString(CountOrders(OP_SELL)) + "\n"
               + "BUY STOP: " + IntegerToString(CountOrders(OP_BUYSTOP)) + "\n"
               + "SELL STOP: " + IntegerToString(CountOrders(OP_SELLSTOP)) + "\n"
               + "Total Lots: " + DoubleToString(lots, 2) + "\n"
               + "Floating: $" + DoubleToString(floating, 2) + "\n"
               + "Drawdown: " + DoubleToString((dd < 0 ? 0 : dd), 2) + "%\n"
               + "Status: " + status;
   
   Comment(dash);
  }
