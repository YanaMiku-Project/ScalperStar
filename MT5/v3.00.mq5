//+------------------------------------------------------------------+
//|                        YANAMIKU_SINGLE_ENTRY_BUY_STOP_SELL_STOP.mq5 |
//|                                   Copyright 2026, Yanamiku Script   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- ENUMS
enum ENUM_TRADING_MODE {
   MODE_1 = 1, // MODE 1 - SINGLE ENTRY TRAILING
   MODE_2 = 2  // MODE 2 - SMART DYNAMIC REVERSAL
};

enum ENUM_EA_STATE {
   STATE_IDLE,
   STATE_INITIAL_PENDING,
   STATE_BUY_ACTIVE,
   STATE_SELL_ACTIVE,
   STATE_RESET
};

//--- INPUTS
input ENUM_TRADING_MODE TradingMode = MODE_1;
input double FixedLot = 0.01;
input double InitialDistancePips = 10.0;
input double InitialSLPips = 10.0;
input double TrailingStartPips = 20.0;
input double TrailingDistancePips = 10.0;
input double TrailingStepPips = 1.0;
input double DynamicPendingDistancePips = 10.0;
input double MinimumOppositeOffsetPips = 0.1;
input double MaxSpreadPips = 0.0; // 0 = tidak membatasi spread
input ulong  MagicNumber = 20260923;
input ulong  MaxSlippagePoints = 20;
input bool   UseTradingSession = false;
input int    StartHour = 0;
input int    EndHour = 23;
input bool   EnableTelegramNotification = false;
input string TelegramBotToken = "";
input string TelegramChatID = "";

//--- GLOBAL VARIABLES
CTrade         trade;
CSymbolInfo    symInfo;
ENUM_EA_STATE  currentState = STATE_IDLE;
double         pipSize = 0.0;
double         minVolume = 0.0;
double         maxVolume = 0.0;
double         volStep = 0.0;
int            digits = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
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
   
   Print("[YANAMIKU] EA INITIALIZED - ", (TradingMode == MODE_1 ? "MODE 1" : "MODE 2"));
   SendTelegramMsg("[YANAMIKU] EA STARTED - " + (TradingMode == MODE_1 ? "MODE 1" : "MODE 2"));
   
   SyncStateFromTerminal();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("[YANAMIKU] EA STOPPED");
}

//+------------------------------------------------------------------+
//| PIP CALCULATION                                                  |
//+------------------------------------------------------------------+
double CalculatePipSize() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 5 || digits == 3) return point * 10.0;
   return point;
}

//+------------------------------------------------------------------+
//| NORMALIZATION                                                    |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| TELEGRAM NOTIFICATION                                            |
//+------------------------------------------------------------------+
void SendTelegramMsg(string msg) {
   if(!EnableTelegramNotification || TelegramBotToken == "" || TelegramChatID == "") return;
   
   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string text = "?chat_id=" + TelegramChatID + "&text=" + msg;
   
   char data[];
   char res[];
   string resHeaders;
   int timeout = 5000;
   
   ResetLastError();
   int result = WebRequest("GET", url + text, "", timeout, data, res, resHeaders);
   if(result == -1) {
      Print("[YANAMIKU] Telegram Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| TRADING SESSION & SPREAD CHECK                                   |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                             |
//+------------------------------------------------------------------+
void OnTick() {
   if(!symInfo.RefreshRates()) return;
   
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double spreadPips = (ask - bid) / pipSize;
   
   SyncStateFromTerminal();
   
   if(currentState == STATE_IDLE || currentState == STATE_RESET) {
      if(!IsTradingSession() || !IsSpreadValid(spreadPips)) return;
      PlaceInitialSetup(ask, bid);
   }
   else if(currentState == STATE_BUY_ACTIVE) {
      ManageBuyActive(ask, bid, spreadPips);
   }
   else if(currentState == STATE_SELL_ACTIVE) {
      ManageSellActive(ask, bid, spreadPips);
   }
}

//+------------------------------------------------------------------+
//| TRADE TRANSACTION (ACCURATE EVENT DETECTION)                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.symbol != _Symbol) return;
   
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      long magic = 0;
      if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC, magic) && magic == MagicNumber) {
         long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         
         if(entryType == DEAL_ENTRY_IN) {
            if(dealType == DEAL_TYPE_BUY) {
               Print("[YANAMIKU] BUY TRIGGERED");
               SendTelegramMsg("[YANAMIKU] BUY TRIGGERED");
               currentState = STATE_BUY_ACTIVE;
               if(TradingMode == MODE_1) DeleteOppositePending(ORDER_TYPE_SELL_STOP);
            }
            else if(dealType == DEAL_TYPE_SELL) {
               Print("[YANAMIKU] SELL TRIGGERED");
               SendTelegramMsg("[YANAMIKU] SELL TRIGGERED");
               currentState = STATE_SELL_ACTIVE;
               if(TradingMode == MODE_1) DeleteOppositePending(ORDER_TYPE_BUY_STOP);
            }
         }
         else if(entryType == DEAL_ENTRY_OUT) {
            Print("[YANAMIKU] POSITION CLOSED");
            SendTelegramMsg("[YANAMIKU] POSITION CLOSED");
            SyncStateFromTerminal(); // Update real-time state
         }
      }
   }
}

//+------------------------------------------------------------------+
//| STATE SYNC & CORE LOGIC                                          |
//+------------------------------------------------------------------+
void SyncStateFromTerminal() {
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         long type = PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY) buyCount++;
         if(type == POSITION_TYPE_SELL) sellCount++;
      }
   }
   
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         long type = OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP) buyStopCount++;
         if(type == ORDER_TYPE_SELL_STOP) sellStopCount++;
      }
   }
   
   if(buyCount > 0 && sellCount > 0) {
      // Force close to ensure max 1 active position
      CloseAllPositions();
      currentState = STATE_RESET;
      return;
   }
   
   if(buyCount == 1) {
      currentState = STATE_BUY_ACTIVE;
      return;
   }
   if(sellCount == 1) {
      currentState = STATE_SELL_ACTIVE;
      return;
   }
   
   if(buyCount == 0 && sellCount == 0) {
      if(buyStopCount == 1 && sellStopCount == 1) {
         currentState = STATE_INITIAL_PENDING;
      } else if(buyStopCount == 0 && sellStopCount == 0) {
         currentState = STATE_IDLE;
      } else {
         // Orphaned pending exists, reset cycle for clean start
         Print("[YANAMIKU] RESET CYCLE");
         SendTelegramMsg("[YANAMIKU] RESET CYCLE");
         DeleteAllPending();
         currentState = STATE_IDLE;
      }
   }
}

//+------------------------------------------------------------------+
//| ORDER MANAGEMENT                                                 |
//+------------------------------------------------------------------+
void PlaceInitialSetup(double ask, double bid) {
   DeleteAllPending();
   
   double vol = GetValidLot();
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * symInfo.Point();
   double minDistance = MathMax(InitialDistancePips * pipSize, stopLevel);
   
   double buyEntry = NormPrice(ask + minDistance);
   double buySL = NormPrice(buyEntry - InitialSLPips * pipSize);
   
   double sellEntry = NormPrice(bid - minDistance);
   double sellSL = NormPrice(sellEntry + InitialSLPips * pipSize);
   
   bool bRes = trade.BuyStop(vol, buyEntry, _Symbol, buySL, 0.0, ORDER_TIME_GTC, 0, "Initial BuyStop");
   bool sRes = trade.SellStop(vol, sellEntry, _Symbol, sellSL, 0.0, ORDER_TIME_GTC, 0, "Initial SellStop");
   
   if(bRes && sRes) {
      Print("[YANAMIKU] BUY STOP PLACED | SELL STOP PLACED");
      SendTelegramMsg("[YANAMIKU] INITIAL PENDING ORDERS PLACED");
      currentState = STATE_INITIAL_PENDING;
   } else {
      Print("[YANAMIKU] Error placing initial pending: ", trade.ResultRetcodeDescription());
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
   
   // TRAILING LOGIC
   if((bid - openPrice) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(bid - TrailingDistancePips * pipSize);
      if(newSL > currentSL + (TrailingStepPips * pipSize) && (bid - newSL) >= stopLevel) {
         if(trade.PositionModify(posTicket, newSL, 0.0)) {
            Print("[YANAMIKU] TRAILING ACTIVATED - SL UPDATED");
         }
      }
   }
   
   // MODE 2 REVERSAL PENDING LOGIC
   if(TradingMode == MODE_2) {
      ulong ssTicket = 0;
      double ssEntry = 0.0;
      double ssSL = 0.0;
      
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         ulong t = OrderGetTicket(i);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_STOP) {
            ssTicket = t;
            ssEntry = OrderGetDouble(ORDER_PRICE_OPEN);
            ssSL = OrderGetDouble(ORDER_SL);
            break;
         }
      }
      
      if(ssTicket > 0) {
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         
         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);
         
         if(targetSSEntry > ssEntry + (TrailingStepPips * pipSize) && (bid - targetSSEntry) >= stopLevel) {
            trade.OrderModify(ssTicket, targetSSEntry, targetSSSL, 0.0, ORDER_TIME_GTC, 0);
         }
      } else {
         // Create reversal pending if missing
         if(!IsSpreadValid(spreadPips)) return;
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);
         if((bid - targetSSEntry) >= stopLevel) {
            trade.SellStop(GetValidLot(), targetSSEntry, _Symbol, targetSSSL, 0.0, ORDER_TIME_GTC, 0, "Reversal SellStop");
         }
      }
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
   
   // TRAILING LOGIC
   if((openPrice - ask) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(ask + TrailingDistancePips * pipSize);
      if((currentSL == 0.0 || newSL < currentSL - (TrailingStepPips * pipSize)) && (newSL - ask) >= stopLevel) {
         if(trade.PositionModify(posTicket, newSL, 0.0)) {
            Print("[YANAMIKU] TRAILING ACTIVATED - SL UPDATED");
         }
      }
   }
   
   // MODE 2 REVERSAL PENDING LOGIC
   if(TradingMode == MODE_2) {
      ulong bsTicket = 0;
      double bsEntry = 0.0;
      double bsSL = 0.0;
      
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         ulong t = OrderGetTicket(i);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP) {
            bsTicket = t;
            bsEntry = OrderGetDouble(ORDER_PRICE_OPEN);
            bsSL = OrderGetDouble(ORDER_SL);
            break;
         }
      }
      
      if(bsTicket > 0) {
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         
         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);
         
         if(targetBSEntry < bsEntry - (TrailingStepPips * pipSize) && (targetBSEntry - ask) >= stopLevel) {
            trade.OrderModify(bsTicket, targetBSEntry, targetBSSL, 0.0, ORDER_TIME_GTC, 0);
         }
      } else {
         // Create reversal pending if missing
         if(!IsSpreadValid(spreadPips)) return;
         double spreadDist = spreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);
         if((targetBSEntry - ask) >= stopLevel) {
            trade.BuyStop(GetValidLot(), targetBSEntry, _Symbol, targetBSSL, 0.0, ORDER_TIME_GTC, 0, "Reversal BuyStop");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UTILITY CLEANUP FUNCTIONS                                        |
//+------------------------------------------------------------------+
void DeleteOppositePending(ENUM_ORDER_TYPE oppositeType) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
         if(OrderGetInteger(ORDER_TYPE) == oppositeType) {
            trade.OrderDelete(ticket);
            Print("[YANAMIKU] PENDING OPPOSITE DELETED");
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
//+------------------------------------------------------------------+
