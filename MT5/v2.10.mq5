#property copyright "YanaMiku"
#property link      ""
#property version   "2.10"

input double InpLotSize              = 0.01;
input double InpPendingDistancePips  = 30.0;
input double InpStopLossPips         = 30.0;
input double InpTrailingStartPips    = 10.0;
input double InpTrailingDistancePips = 10.0;
input ulong  InpMagicNumber          = 20260921;
input int    InpDeviationPoints      = 20;

double m_pip_size;

int OnInit()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      m_pip_size = point * 10.0;
   else
      m_pip_size = point;
      
   Print("[EA] Initializing... Pip Size = ", DoubleToString(m_pip_size, digits));
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
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
        }
     }
   return count;
  }

int CountOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
        {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            count++;
        }
     }
   return count;
  }

void DeleteAllOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
        {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
           {
            MqlTradeRequest request={0};
            MqlTradeResult result={0};
            request.action = TRADE_ACTION_REMOVE;
            request.order = ticket;
            
            if(OrderSend(request, result))
               Print("[EA] Pending order terhapus. Ticket: ", ticket);
            else
               Print("[EA] Gagal menghapus order. Ticket: ", ticket, " Error: ", result.retcode);
           }
        }
     }
  }

void PlacePendingOrders()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   double pendingDist = InpPendingDistancePips * m_pip_size;
   double slDist = InpStopLossPips * m_pip_size;
   
   if(pendingDist <= stopsLevel)
     {
      Print("[EA] Warning: Pending Distance terlalu dekat dengan Stops Level broker!");
      return;
     }

   double buyStopPrice = NormalizeDouble(ask + pendingDist, digits);
   double buySL = NormalizeDouble(buyStopPrice - slDist, digits);
   
   double sellStopPrice = NormalizeDouble(bid - pendingDist, digits);
   double sellSL = NormalizeDouble(sellStopPrice + slDist, digits);
   
   MqlTradeRequest reqBuy={0};
   MqlTradeResult resBuy={0};
   reqBuy.action = TRADE_ACTION_PENDING;
   reqBuy.symbol = _Symbol;
   reqBuy.volume = InpLotSize;
   reqBuy.price = buyStopPrice;
   reqBuy.sl = buySL;
   reqBuy.type = ORDER_TYPE_BUY_STOP;
   reqBuy.magic = InpMagicNumber;
   reqBuy.deviation = InpDeviationPoints;
   reqBuy.comment = "Yanamiku BuyStop";
   
   if(OrderSend(reqBuy, resBuy))
      Print("[EA] BUY STOP placed at: ", buyStopPrice, " SL: ", buySL);
   else
     {
      Print("[EA] Error menempatkan BUY STOP: ", resBuy.retcode);
      return;
     }
      
   MqlTradeRequest reqSell={0};
   MqlTradeResult resSell={0};
   reqSell.action = TRADE_ACTION_PENDING;
   reqSell.symbol = _Symbol;
   reqSell.volume = InpLotSize;
   reqSell.price = sellStopPrice;
   reqSell.sl = sellSL;
   reqSell.type = ORDER_TYPE_SELL_STOP;
   reqSell.magic = InpMagicNumber;
   reqSell.deviation = InpDeviationPoints;
   reqSell.comment = "Yanamiku SellStop";
   
   if(OrderSend(reqSell, resSell))
      Print("[EA] SELL STOP placed at: ", sellStopPrice, " SL: ", sellSL);
   else
      Print("[EA] Error menempatkan SELL STOP: ", resSell.retcode);
  }

void ManageTrailingStop()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            long type = PositionGetInteger(POSITION_TYPE);
            
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            double trailingStart = InpTrailingStartPips * m_pip_size;
            double trailingDist  = InpTrailingDistancePips * m_pip_size;
            
            if(type == POSITION_TYPE_BUY)
              {
               double profit = bid - openPrice;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(bid - trailingDist, digits);
                  
                  if((newSL > currentSL + point || currentSL == 0.0) && newSL <= (bid - stopsLevel))
                    {
                     MqlTradeRequest req={0};
                     MqlTradeResult res={0};
                     req.action = TRADE_ACTION_SLTP;
                     req.position = ticket;
                     req.symbol = _Symbol;
                     req.sl = newSL;
                     req.tp = PositionGetDouble(POSITION_TP);
                     
                     if(OrderSend(req, res))
                        Print("[EA] Trailing SL BUY modified to: ", newSL);
                    }
                 }
              }
            else if(type == POSITION_TYPE_SELL)
              {
               double profit = openPrice - ask;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(ask + trailingDist, digits);
                  
                  if((newSL < currentSL - point || currentSL == 0.0) && newSL >= (ask + stopsLevel))
                    {
                     MqlTradeRequest req={0};
                     MqlTradeResult res={0};
                     req.action = TRADE_ACTION_SLTP;
                     req.position = ticket;
                     req.symbol = _Symbol;
                     req.sl = newSL;
                     req.tp = PositionGetDouble(POSITION_TP);
                     
                     if(OrderSend(req, res))
                        Print("[EA] Trailing SL SELL modified to: ", newSL);
                    }
                 }
              }
           }
        }
     }
  }
