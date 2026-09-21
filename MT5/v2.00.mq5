#property copyright "YanaMiku"
#property link      ""
#property version   "2.00"
#property description "Scalping Single Entry with Pending Orders and Trailing Stop"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input double InpLotSize              = 0.01;
input double InpPendingDistancePips  = 30.0;
input double InpStopLossPips         = 30.0;
input double InpTrailingStartPips    = 10.0;
input double InpTrailingDistancePips = 10.0;
input ulong  InpMagicNumber          = 20260921;
input int    InpDeviationPoints      = 20;

CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
COrderInfo     m_order;
double         m_pip_size;

int OnInit()
  {
   if(!m_symbol.Name(_Symbol))
     {
      Print("[EA] Error menginisialisasi symbol.");
      return(INIT_FAILED);
     }
   
   m_symbol.RefreshRates();
   
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpDeviationPoints);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   int digits = m_symbol.Digits();
   if(digits == 3 || digits == 5)
      m_pip_size = m_symbol.Point() * 10.0;
   else
      m_pip_size = m_symbol.Point();
      
   Print("[EA] Initializing... Pip Size = ", DoubleToString(m_pip_size, digits));
   
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Print("[EA] EA Deinitialized. Reason: ", reason);
  }

void OnTick()
  {
   if(!m_symbol.RefreshRates()) return;
   
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
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
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
      if(m_order.SelectByIndex(i))
        {
         if(m_order.Symbol() == _Symbol && m_order.Magic() == InpMagicNumber)
            count++;
        }
     }
   return count;
  }

void DeleteAllOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(m_order.SelectByIndex(i))
        {
         if(m_order.Symbol() == _Symbol && m_order.Magic() == InpMagicNumber)
           {
            ulong ticket = m_order.Ticket();
            if(m_trade.OrderDelete(ticket))
               Print("[EA] Pending order terhapus. Ticket: ", ticket);
            else
               Print("[EA] Gagal menghapus order. Ticket: ", ticket, " Error: ", m_trade.ResultRetcode());
           }
        }
     }
  }

void PlacePendingOrders()
  {
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();
   
   double stopsLevel = m_symbol.StopsLevel() * m_symbol.Point();
   double pendingDist = InpPendingDistancePips * m_pip_size;
   double slDist = InpStopLossPips * m_pip_size;
   
   if(pendingDist <= stopsLevel)
     {
      Print("[EA] Warning: Pending Distance terlalu dekat dengan Stops Level broker!");
      return;
     }

   double buyStopPrice = NormalizeDouble(ask + pendingDist, m_symbol.Digits());
   double buySL = NormalizeDouble(buyStopPrice - slDist, m_symbol.Digits());
   
   double sellStopPrice = NormalizeDouble(bid - pendingDist, m_symbol.Digits());
   double sellSL = NormalizeDouble(sellStopPrice + slDist, m_symbol.Digits());
   
   if(m_trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, buySL, 0.0, ORDER_TIME_GTC, 0, "Yanamiku BuyStop"))
      Print("[EA] BUY STOP placed at: ", buyStopPrice, " SL: ", buySL);
   else
     {
      Print("[EA] Error menempatkan BUY STOP: ", m_trade.ResultRetcode());
      return;
     }
      
   if(m_trade.SellStop(InpLotSize, sellStopPrice, _Symbol, sellSL, 0.0, ORDER_TIME_GTC, 0, "Yanamiku SellStop"))
      Print("[EA] SELL STOP placed at: ", sellStopPrice, " SL: ", sellSL);
   else
      Print("[EA] Error menempatkan SELL STOP: ", m_trade.ResultRetcode());
  }

void ManageTrailingStop()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            double openPrice = m_position.PriceOpen();
            double currentSL = m_position.StopLoss();
            ENUM_POSITION_TYPE type = m_position.PositionType();
            ulong ticket = m_position.Ticket();
            
            double bid = m_symbol.Bid();
            double ask = m_symbol.Ask();
            
            double trailingStart = InpTrailingStartPips * m_pip_size;
            double trailingDist  = InpTrailingDistancePips * m_pip_size;
            
            if(type == POSITION_TYPE_BUY)
              {
               double profit = bid - openPrice;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(bid - trailingDist, m_symbol.Digits());
                  
                  if((newSL > currentSL + m_symbol.Point() || currentSL == 0.0) && newSL <= (bid - m_symbol.StopsLevel() * m_symbol.Point()))
                    {
                     if(m_trade.PositionModify(ticket, newSL, 0.0))
                        Print("[EA] Trailing SL BUY modified to: ", newSL);
                    }
                 }
              }
            else if(type == POSITION_TYPE_SELL)
              {
               double profit = openPrice - ask;
               if(profit >= trailingStart)
                 {
                  double newSL = NormalizeDouble(ask + trailingDist, m_symbol.Digits());
                  
                  if((newSL < currentSL - m_symbol.Point() || currentSL == 0.0) && newSL >= (ask + m_symbol.StopsLevel() * m_symbol.Point()))
                    {
                     if(m_trade.PositionModify(ticket, newSL, 0.0))
                        Print("[EA] Trailing SL SELL modified to: ", newSL);
                    }
                 }
              }
           }
        }
     }
  }
