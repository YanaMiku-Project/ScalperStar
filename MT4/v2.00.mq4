#property copyright "YanaMiku"
#property link      ""
#property version   "2.00"
#property strict

input double InpLotSize              = 0.01;
input double InpPendingDistancePips  = 30.0;
input double InpStopLossPips         = 30.0;
input double InpTrailingStartPips    = 10.0;
input double InpTrailingDistancePips = 10.0;
input int    InpMagicNumber          = 20260921;
input int    InpDeviationPoints      = 20;

double m_pip_size;

int OnInit()
  {
   if(Digits == 3 || Digits == 5)
      m_pip_size = Point * 10.0;
   else
      m_pip_size = Point;
      
   Print("[EA] Initializing... Pip Size = ", DoubleToString(m_pip_size, Digits));
   
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Print("[EA] EA Deinitialized. Reason: ", reason);
  }

void OnTick()
  {
   int posCount = CountPositions();
   int orderCount = CountOrders();
   
   if(posCount == 0 && orderCount == 0)
     {
      Print("[EA] Reset cycle started. Menempatkan Pending Order baru.");
      PlacePendingOrders();
     }
   else if(posCount == 0 && orderCount != 2)
     {
      Print("[EA] Membersihkan pending order anomali untuk RESET...");
      DeleteAllOrders();
     }
   else if(posCount == 1)
     {
      if(orderCount > 0)
        {
         Print("[EA] Posisi ter-trigger! Menghapus sisa Pending Order.");
         DeleteAllOrders();
        }
        
      ManageTrailingStop();
     }
  }

int CountPositions()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagicNumber)
           {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
               count++;
           }
        }
     }
   return count;
  }

int CountOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagicNumber)
           {
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
               count++;
           }
        }
     }
   return count;
  }

void DeleteAllOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagicNumber)
           {
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
              {
               int ticket = OrderTicket();
               if(OrderDelete(ticket))
                  Print("[EA] Pending order terhapus. Ticket: ", ticket);
               else
                  Print("[EA] Gagal menghapus order. Ticket: ", ticket, " Error: ", GetLastError());
              }
           }
        }
     }
  }

void PlacePendingOrders()
  {
   double stopsLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double pendingDist = InpPendingDistancePips * m_pip_size;
   double slDist = InpStopLossPips * m_pip_size;
   
   if(pendingDist <= stopsLevel)
     {
      Print("[EA] Warning: Pending Distance terlalu dekat dengan Stops Level broker!");
      return;
     }

   double buyStopPrice = NormalizeDouble(Ask + pendingDist, Digits);
   double buySL = NormalizeDouble(buyStopPrice - slDist, Digits);
   
   double sellStopPrice = NormalizeDouble(Bid - pendingDist, Digits);
   double sellSL = NormalizeDouble(sellStopPrice + slDist, Digits);
   
   int ticketBuy = OrderSend(Symbol(), OP_BUYSTOP, InpLotSize, buyStopPrice, InpDeviationPoints, buySL, 0, "Yanamiku BuyStop", InpMagicNumber, 0, clrBlue);
   if(ticketBuy > 0)
      Print("[EA] BUY STOP placed at: ", buyStopPrice, " SL: ", buySL);
   else
     {
      Print("[EA] Error menempatkan BUY STOP: ", GetLastError());
      return;
     }
      
   int ticketSell = OrderSend(Symbol(), OP_SELLSTOP, InpLotSize, sellStopPrice, InpDeviationPoints, sellSL, 0, "Yanamiku SellStop", InpMagicNumber, 0, clrRed);
   if(ticketSell > 0)
      Print("[EA] SELL STOP placed at: ", sellStopPrice, " SL: ", sellSL);
   else
      Print("[EA] Error menempatkan SELL STOP: ", GetLastError());
  }

void ManageTrailingStop()
  {
   double stopsLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagicNumber)
           {
            double openPrice = OrderOpenPrice();
            double currentSL = OrderStopLoss();
            int type = OrderType();
            int ticket = OrderTicket();
            
            double trailingStart = InpTrailingStartPips * m_pip_size;
            double trailingDist  = InpTrailingDistancePips * m_pip_size;
            
            if(type == OP_BUY)
              {
               double profit = Bid - openPrice;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(Bid - trailingDist, Digits);
                  
                  if((newSL > currentSL + Point || currentSL == 0.0) && newSL <= Bid - stopsLevel)
                    {
                     if(OrderModify(ticket, openPrice, newSL, OrderTakeProfit(), 0, clrGreen))
                        Print("[EA] Trailing SL BUY modified to: ", newSL);
                    }
                 }
              }
            else if(type == OP_SELL)
              {
               double profit = openPrice - Ask;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(Ask + trailingDist, Digits);
                  
                  if((newSL < currentSL - Point || currentSL == 0.0) && newSL >= Ask + stopsLevel)
                    {
                     if(OrderModify(ticket, openPrice, newSL, OrderTakeProfit(), 0, clrRed))
                        Print("[EA] Trailing SL SELL modified to: ", newSL);
                    }
                 }
              }
           }
        }
     }
  }
