#property copyright "YanaMiku"
#property link      "t.me/YanaMiku"
#property version   "3.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

enum ENUM_TRADING_MODE {
   MODE_1 = 1,
   MODE_2 = 2
};

enum ENUM_EA_STATE {
   STATE_IDLE,
   STATE_BUY_ACTIVE,
   STATE_SELL_ACTIVE,
   STATE_RESET
};

input ENUM_TRADING_MODE TradingMode = MODE_1;
input double FixedLot = 0.01;
input double InitialDistancePips = 10.0;
input double InitialSLPips = 10.0;
input double TrailingStartPips = 20.0;
input double TrailingDistancePips = 10.0;
input double TrailingStepPips = 1.0;
input double DynamicPendingDistancePips = 10.0;
input double MinimumOppositeOffsetPips = 0.1;
input double MaxSpreadPips = 0.0;
input ulong  MagicNumber = 20260923;
input ulong  MaxSlippagePoints = 20;
input bool   UseTradingSession = false;
input int    StartHour = 0;
input int    EndHour = 23;
input bool   EnableTelegramNotification = false;
input string TelegramBotToken = "";
input string TelegramChatID = "";

CTrade         trade;
CSymbolInfo    symInfo;
ENUM_EA_STATE  currentState = STATE_IDLE;
ENUM_EA_STATE  lastState = STATE_IDLE;
double         pipSize = 0.0;
double         minVolume = 0.0;
double         maxVolume = 0.0;
double         volStep = 0.0;
int            digits = 0;

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   symInfo.Name(_Symbol);
   symInfo.Refresh();
   
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pipSize = CalculatePipSize();
   
   minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   SyncStateFromTerminal();
   lastState = currentState;
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
}

double CalculatePipSize() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 5 || digits == 3) return point * 10.0;
   return point;
}

double NormPrice(double price) {
   return NormalizeDouble(price, digits);
}

double GetValidLot() {
   double lot = FixedLot;
   if(lot < minVolume) lot = minVolume;
   if(lot > maxVolume) lot = maxVolume;
   lot = MathRound(lot / volStep) * volStep;
   return lot;
}

bool IsTradingSession() {
   if(!UseTradingSession) return true;
   MqlDateTime time;
   TimeCurrent(time);
   if(StartHour <= EndHour) {
      return (time.hour >= StartHour && time.hour <= EndHour);
   } else {
      return (time.hour >= StartHour || time.hour <= EndHour);
   }
}

bool IsSpreadValid(double currentSpreadPips) {
   if(MaxSpreadPips <= 0.0) return true;
   return (currentSpreadPips <= MaxSpreadPips);
}

int CountOrders(ENUM_ORDER_TYPE orderType) {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         if(OrderGetInteger(ORDER_TYPE) == orderType) count++;
      }
   }
   return count;
}

ulong GetOrderTicketByType(ENUM_ORDER_TYPE orderType) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         if(OrderGetInteger(ORDER_TYPE) == orderType) return ticket;
      }
   }
   return 0;
}

void DeleteExtraPending(ENUM_ORDER_TYPE orderType) {
   bool keptOne = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         if(OrderGetInteger(ORDER_TYPE) == orderType) {
            if(!keptOne) {
               keptOne = true;
            } else {
               trade.OrderDelete(ticket);
            }
         }
      }
   }
}

void CloseExtraPositions(ENUM_POSITION_TYPE posType) {
   bool keptOne = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         if(PositionGetInteger(POSITION_TYPE) == posType) {
            if(!keptOne) {
               keptOne = true;
            } else {
               trade.PositionClose(ticket);
            }
         }
      }
   }
}

void DeleteAllPending() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         trade.OrderDelete(ticket);
      }
   }
}

void CloseAllPositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         trade.PositionClose(ticket);
      }
   }
}

void SyncStateFromTerminal() {
   int buyCount = 0, sellCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         long type = PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY) buyCount++;
         if(type == POSITION_TYPE_SELL) sellCount++;
      }
   }
   
   if(buyCount > 0 && sellCount > 0) {
      CloseAllPositions();
      currentState = STATE_RESET;
      return;
   }
   
   if(buyCount > 0) {
      if(buyCount > 1) CloseExtraPositions(POSITION_TYPE_BUY);
      currentState = STATE_BUY_ACTIVE;
      return;
   }
   
   if(sellCount > 0) {
      if(sellCount > 1) CloseExtraPositions(POSITION_TYPE_SELL);
      currentState = STATE_SELL_ACTIVE;
      return;
   }
   
   currentState = STATE_IDLE;
}

void ManageInitialPending(double ask, double bid) {
   int bsCount = CountOrders(ORDER_TYPE_BUY_STOP);
   int ssCount = CountOrders(ORDER_TYPE_SELL_STOP);
   
   if(bsCount > 1) { DeleteExtraPending(ORDER_TYPE_BUY_STOP); bsCount = 1; }
   if(ssCount > 1) { DeleteExtraPending(ORDER_TYPE_SELL_STOP); ssCount = 1; }
   
   if(bsCount > 0 && ssCount > 0) return;
   
   double vol = GetValidLot();
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * symInfo.Point();
   double minDistance = MathMax(InitialDistancePips * pipSize, stopLevel);
   
   if(bsCount == 0) {
      double buyEntry = NormPrice(ask + minDistance);
      double buySL = NormPrice(buyEntry - InitialSLPips * pipSize);
      trade.BuyStop(vol, buyEntry, _Symbol, buySL, 0.0, ORDER_TIME_GTC, 0, "");
   }
   
   if(ssCount == 0) {
      double sellEntry = NormPrice(bid - minDistance);
      double sellSL = NormPrice(sellEntry + InitialSLPips * pipSize);
      trade.SellStop(vol, sellEntry, _Symbol, sellSL, 0.0, ORDER_TIME_GTC, 0, "");
   }
}

void ManageBuyActive(double ask, double bid, double spreadPips) {
   ulong posTicket = 0;
   double openPrice = 0.0;
   double currentSL = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         posTicket = t;
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         currentSL = PositionGetDouble(POSITION_SL);
         break;
      }
   }
   
   if(posTicket == 0) return;
   
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * symInfo.Point();
   
   if((bid - openPrice) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(bid - TrailingDistancePips * pipSize);
      if(newSL > currentSL + (TrailingStepPips * pipSize) && (bid - newSL) >= stopLevel) {
         trade.PositionModify(posTicket, newSL, 0.0);
      }
   }
   
   if(TradingMode == MODE_2) {
      int ssCount = CountOrders(ORDER_TYPE_SELL_STOP);
      if(ssCount > 1) DeleteExtraPending(ORDER_TYPE_SELL_STOP);
      
      ulong ssTicket = GetOrderTicketByType(ORDER_TYPE_SELL_STOP);
      
      if(ssTicket > 0 && OrderSelect(ssTicket)) {
         double ssEntry = OrderGetDouble(ORDER_PRICE_OPEN);
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         
         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);
         
         if(targetSSEntry > ssEntry + (TrailingStepPips * pipSize) && (bid - targetSSEntry) >= stopLevel) {
            trade.OrderModify(ssTicket, targetSSEntry, targetSSSL, 0.0, ORDER_TIME_GTC, 0);
         }
      } else if(ssTicket == 0) {
         if(!IsSpreadValid(spreadPips)) return;
         double vol = GetValidLot();
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);
         
         if((bid - targetSSEntry) >= stopLevel) {
            trade.SellStop(vol, targetSSEntry, _Symbol, targetSSSL, 0.0, ORDER_TIME_GTC, 0, "");
         }
      }
   } else {
      DeleteAllPending();
   }
}

void ManageSellActive(double ask, double bid, double spreadPips) {
   ulong posTicket = 0;
   double openPrice = 0.0;
   double currentSL = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
         posTicket = t;
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         currentSL = PositionGetDouble(POSITION_SL);
         break;
      }
   }
   
   if(posTicket == 0) return;
   
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * symInfo.Point();
   
   if((openPrice - ask) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(ask + TrailingDistancePips * pipSize);
      if((currentSL == 0.0 || newSL < currentSL - (TrailingStepPips * pipSize)) && (newSL - ask) >= stopLevel) {
         trade.PositionModify(posTicket, newSL, 0.0);
      }
   }
   
   if(TradingMode == MODE_2) {
      int bsCount = CountOrders(ORDER_TYPE_BUY_STOP);
      if(bsCount > 1) DeleteExtraPending(ORDER_TYPE_BUY_STOP);
      
      ulong bsTicket = GetOrderTicketByType(ORDER_TYPE_BUY_STOP);
      
      if(bsTicket > 0 && OrderSelect(bsTicket)) {
         double bsEntry = OrderGetDouble(ORDER_PRICE_OPEN);
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         
         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);
         
         if(targetBSEntry < bsEntry - (TrailingStepPips * pipSize) && (targetBSEntry - ask) >= stopLevel) {
            trade.OrderModify(bsTicket, targetBSEntry, targetBSSL, 0.0, ORDER_TIME_GTC, 0);
         }
      } else if(bsTicket == 0) {
         if(!IsSpreadValid(spreadPips)) return;
         double vol = GetValidLot();
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);
         
         if((targetBSEntry - ask) >= stopLevel) {
            trade.BuyStop(vol, targetBSEntry, _Symbol, targetBSSL, 0.0, ORDER_TIME_GTC, 0, "");
         }
      }
   } else {
      DeleteAllPending();
   }
}

void OnTick() {
   if(!symInfo.RefreshRates()) return;
   
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double spreadPips = (ask - bid) / pipSize;
   
   SyncStateFromTerminal();
   
   if(currentState != lastState) {
      if(currentState == STATE_IDLE && (lastState == STATE_BUY_ACTIVE || lastState == STATE_SELL_ACTIVE || lastState == STATE_RESET)) {
         DeleteAllPending();
      }
      lastState = currentState;
   }
   
   if(currentState == STATE_IDLE || currentState == STATE_RESET) {
      if(!IsTradingSession() || !IsSpreadValid(spreadPips)) return;
      ManageInitialPending(ask, bid);
   }
   else if(currentState == STATE_BUY_ACTIVE) {
      ManageBuyActive(ask, bid, spreadPips);
   }
   else if(currentState == STATE_SELL_ACTIVE) {
      ManageSellActive(ask, bid, spreadPips);
   }
}
