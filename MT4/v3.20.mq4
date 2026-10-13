#property copyright "YanaMiku"
#property link      "t.me/YanaMiku"
#property version   "3.20"
#property strict

enum ENUM_TRADING_MODE {
   TMODE_1 = 1,
   TMODE_2 = 2
};

enum ENUM_EA_STATE {
   STATE_IDLE,
   STATE_INITIAL_PENDING,
   STATE_BUY_ACTIVE,
   STATE_SELL_ACTIVE,
   STATE_RESET
};

input ENUM_TRADING_MODE TradingMode = TMODE_1;
input double FixedLot = 0.01;
input double InitialDistancePips = 10.0;
input double InitialSLPips = 40.0;
input double TrailingStartPips = 20.0;
input double TrailingDistancePips = 10.0;
input double TrailingStepPips = 1.0;
input double DynamicPendingDistancePips = 10.0;
input double MinimumOppositeOffsetPips = 0.1;
input double FixedSpreadPips = 2.0;
input double MaxSpreadPips = 0.0;
input int    MagicNumber = 20260923;
input int    MaxSlippagePoints = 20;
input bool   UseTradingSession = false;
input int    StartHour = 0;
input int    EndHour = 23;
input bool   EnableTelegramNotification = false;
input string TelegramBotToken = "";
input string TelegramChatID = "";

ENUM_EA_STATE  currentState = STATE_IDLE;
double         pipSize = 0.0;
double         minVolume = 0.0;
double         maxVolume = 0.0;
double         volStep = 0.0;
int            eaDigits = 0;
int            lotDigits = 2;
int            trackedTicket = 0;      // tiket posisi aktif yang sedang dilacak (pengganti OnTradeTransaction)
bool           syncInitialized = false;

//+------------------------------------------------------------------+
int OnInit() {
   LoadSymbolSpecs();

   Print("[ScalperStar] EA INITIALIZED - ", (TradingMode == TMODE_1 ? "MODE 1" : "MODE 2"));
   SendTelegramMsg("[ScalperStar] EA STARTED - " + (TradingMode == TMODE_1 ? "MODE 1" : "MODE 2"));

   SyncStateFromTerminal();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("[ScalperStar] EA STOPPED");
}

//+------------------------------------------------------------------+
void LoadSymbolSpecs() {
   eaDigits  = Digits;
   pipSize   = CalculatePipSize();
   minVolume = MarketInfo(Symbol(), MODE_MINLOT);
   maxVolume = MarketInfo(Symbol(), MODE_MAXLOT);
   volStep   = MarketInfo(Symbol(), MODE_LOTSTEP);

   // Jumlah desimal lot mengikuti lot step broker (0.01 -> 2, 0.001 -> 3, 1 -> 0)
   lotDigits = 2;
   if(volStep > 0.0) {
      lotDigits = 0;
      while(lotDigits < 8) {
         double scaled = volStep * MathPow(10.0, lotDigits);
         if(MathAbs(scaled - MathRound(scaled)) < 0.00000001) break;
         lotDigits++;
      }
   }
}

double CalculatePipSize() {
   if(Digits == 5 || Digits == 3) return Point * 10.0;
   return Point;
}

double NormPrice(double price) {
   return NormalizeDouble(price, eaDigits);
}

double GetStopLevel() {
   return MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
}

double GetValidLot() {
   double lot = FixedLot;
   if(lot < minVolume && minVolume > 0.0) lot = minVolume;
   if(lot > maxVolume && maxVolume > 0.0) lot = maxVolume;

   // Mencegah Zero Divide Crash jika broker belum mengirim data spesifikasi
   if(volStep > 0.0) {
      lot = MathRound(lot / volStep) * volStep;
      if(lot < minVolume && minVolume > 0.0) lot = minVolume;
      if(lot > maxVolume && maxVolume > 0.0) lot = maxVolume;
   }
   return NormalizeDouble(lot, lotDigits);
}

//+------------------------------------------------------------------+
string UrlEncode(string s) {
   StringReplace(s, "%", "%25");
   StringReplace(s, " ", "%20");
   StringReplace(s, "[", "%5B");
   StringReplace(s, "]", "%5D");
   StringReplace(s, "|", "%7C");
   StringReplace(s, "#", "%23");
   StringReplace(s, "&", "%26");
   StringReplace(s, "+", "%2B");
   return s;
}

void SendTelegramMsg(string msg) {
   if(!EnableTelegramNotification || TelegramBotToken == "" || TelegramChatID == "") return;

   string url  = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string text = "?chat_id=" + TelegramChatID + "&text=" + UrlEncode(msg);

   char data[];
   char res[];
   string resHeaders;
   int timeout = 5000;

   ArrayResize(data, 0);
   ResetLastError();
   int result = WebRequest("GET", url + text, "", timeout, data, res, resHeaders);
   if(result == -1) {
      Print("[ScalperStar] Telegram Error: ", GetLastError(), " (pastikan https://api.telegram.org sudah di-whitelist di Tools > Options > Expert Advisors)");
   }
}

bool IsTradingSession() {
   if(!UseTradingSession) return true;
   int h = TimeHour(TimeCurrent());
   if(StartHour <= EndHour) {
      return (h >= StartHour && h <= EndHour);
   } else {
      return (h >= StartHour || h <= EndHour);
   }
}

bool IsSpreadValid(double currentSpreadPips) {
   if(MaxSpreadPips <= 0.0) return true;
   return (currentSpreadPips <= MaxSpreadPips);
}

//+------------------------------------------------------------------+
void OnTick() {
   double ask = Ask;
   double bid = Bid;

   if(ask <= 0.0 || bid <= 0.0) return;

   // Safety Check: Rekalkulasi jika variabel krusial gagal didapat saat OnInit
   if(pipSize <= 0.0 || volStep <= 0.0 || eaDigits <= 0) {
      LoadSymbolSpecs();
      if(pipSize <= 0.0 || volStep <= 0.0) return; // Tunggu tick berikutnya
   }

   if(!IsConnected() || !IsTradeAllowed()) return;

   double spreadPips = (ask - bid) / pipSize;

   SyncStateFromTerminal();

   if(currentState == STATE_IDLE || currentState == STATE_RESET) {
      if(!IsTradingSession() || !IsSpreadValid(spreadPips)) return;
      PlaceInitialSetup();
   }
   else if(currentState == STATE_BUY_ACTIVE) {
      ManageBuyActive(ask, bid, spreadPips);
   }
   else if(currentState == STATE_SELL_ACTIVE) {
      ManageSellActive(ask, bid, spreadPips);
   }
}

//+------------------------------------------------------------------+
bool IsOurOrder() {
   return (OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber);
}

// Mencari posisi market (OP_BUY / OP_SELL) milik EA ini
bool FindPosition(int type, int &ticket, double &openPrice, double &sl, double &tp) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      if(OrderType() != type) continue;
      ticket    = OrderTicket();
      openPrice = OrderOpenPrice();
      sl        = OrderStopLoss();
      tp        = OrderTakeProfit();
      return true;
   }
   return false;
}

// Mencari pending order (OP_BUYSTOP / OP_SELLSTOP) milik EA ini
bool FindPending(int type, int &ticket, double &entry, double &sl) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      if(OrderType() != type) continue;
      ticket = OrderTicket();
      entry  = OrderOpenPrice();
      sl     = OrderStopLoss();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void SyncStateFromTerminal() {
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   int singleTicket = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      int type = OrderType();
      if(type == OP_BUY)      { buyCount++;      singleTicket = OrderTicket(); }
      if(type == OP_SELL)     { sellCount++;     singleTicket = OrderTicket(); }
      if(type == OP_BUYSTOP)  buyStopCount++;
      if(type == OP_SELLSTOP) sellStopCount++;
   }

   int curTicket = ((buyCount + sellCount) == 1) ? singleTicket : 0;

   // Sinkronisasi pertama (saat EA dipasang): catat posisi yang sudah ada tanpa notifikasi
   if(!syncInitialized) {
      trackedTicket = curTicket;
      syncInitialized = true;
   }

   if(buyCount > 0 && sellCount > 0) {
      CloseAllPositions();
      if(trackedTicket != 0) {
         Print("[ScalperStar] POSITION CLOSED");
         SendTelegramMsg("[ScalperStar] POSITION CLOSED");
      }
      trackedTicket = 0;
      currentState = STATE_RESET;
      return;
   }

   // Deteksi event trade (pengganti OnTradeTransaction di MT5)
   if(curTicket != 0 && curTicket != trackedTicket) {
      if(trackedTicket != 0) {
         Print("[ScalperStar] POSITION CLOSED");
         SendTelegramMsg("[ScalperStar] POSITION CLOSED");
      }
      trackedTicket = curTicket;
      if(buyCount == 1) {
         Print("[ScalperStar] BUY TRIGGERED");
         SendTelegramMsg("[ScalperStar] BUY TRIGGERED");
         if(TradingMode == TMODE_1) DeleteOppositePending(OP_SELLSTOP);
      } else {
         Print("[ScalperStar] SELL TRIGGERED");
         SendTelegramMsg("[ScalperStar] SELL TRIGGERED");
         if(TradingMode == TMODE_1) DeleteOppositePending(OP_BUYSTOP);
      }
   }
   else if(buyCount == 0 && sellCount == 0 && trackedTicket != 0) {
      Print("[ScalperStar] POSITION CLOSED");
      SendTelegramMsg("[ScalperStar] POSITION CLOSED");
      trackedTicket = 0;
   }

   if(buyCount == 1 && sellCount == 0) {
      currentState = STATE_BUY_ACTIVE;
      return;
   }
   if(sellCount == 1 && buyCount == 0) {
      currentState = STATE_SELL_ACTIVE;
      return;
   }

   if(buyCount == 0 && sellCount == 0) {
      if(buyStopCount == 1 && sellStopCount == 1) {
         currentState = STATE_INITIAL_PENDING;
      } else if(buyStopCount == 0 && sellStopCount == 0) {
         currentState = STATE_IDLE;
      } else {
         Print("[ScalperStar] RESET CYCLE - Membersihkan sisa order...");
         DeleteAllPending();
         currentState = STATE_IDLE;
      }
   }
}

//+------------------------------------------------------------------+
void PlaceInitialSetup() {
   DeleteAllPending();
   RefreshRates();

   double ask = Ask;
   double bid = Bid;
   if(ask <= 0.0 || bid <= 0.0) return;

   double vol = GetValidLot();
   double stopLevel = GetStopLevel();
   double minDistance = MathMax(InitialDistancePips * pipSize, stopLevel);

   double buyEntry = NormPrice(ask + minDistance);
   double buySL    = NormPrice(buyEntry - InitialSLPips * pipSize);

   double sellEntry = NormPrice(bid - minDistance);
   double sellSL    = NormPrice(sellEntry + InitialSLPips * pipSize);

   ResetLastError();
   int bTicket = OrderSend(Symbol(), OP_BUYSTOP, vol, buyEntry, MaxSlippagePoints, buySL, 0.0, "Initial BuyStop", MagicNumber, 0, clrNONE);
   int bErr = (bTicket < 0) ? GetLastError() : 0;

   ResetLastError();
   int sTicket = OrderSend(Symbol(), OP_SELLSTOP, vol, sellEntry, MaxSlippagePoints, sellSL, 0.0, "Initial SellStop", MagicNumber, 0, clrNONE);
   int sErr = (sTicket < 0) ? GetLastError() : 0;

   if(bTicket > 0 && sTicket > 0) {
      Print("[ScalperStar] BUY STOP PLACED | SELL STOP PLACED");
      SendTelegramMsg("[ScalperStar] INITIAL PENDING ORDERS PLACED");
      currentState = STATE_INITIAL_PENDING;
   } else {
      // Menampilkan Log Error Spesifik Jika Ditolak Broker
      Print("[ScalperStar] GAGAL ENTRY! Cek kode error berikut:");
      if(bTicket < 0) Print("BuyStop Error: ", bErr, " | Ask: ", ask, " | Entry Target: ", buyEntry, " | SL: ", buySL);
      if(sTicket < 0) Print("SellStop Error: ", sErr, " | Bid: ", bid, " | Entry Target: ", sellEntry, " | SL: ", sellSL);
   }
}

//+------------------------------------------------------------------+
void ManageBuyActive(double ask, double bid, double spreadPips) {
   int posTicket = 0;
   double openPrice = 0.0, currentSL = 0.0, currentTP = 0.0;

   if(!FindPosition(OP_BUY, posTicket, openPrice, currentSL, currentTP)) return;
   if(posTicket == 0) return;

   double stopLevel = GetStopLevel();

   if((bid - openPrice) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(bid - TrailingDistancePips * pipSize);
      if(newSL > currentSL + (TrailingStepPips * pipSize) && (bid - newSL) >= stopLevel) {
         if(OrderModify(posTicket, openPrice, newSL, currentTP, 0, clrNONE)) {
            Print("[ScalperStar] TRAILING ACTIVATED - SL UPDATED");
         } else {
            Print("[ScalperStar] Trailing BUY gagal. Error: ", GetLastError());
         }
      }
   }

   if(TradingMode == TMODE_2) {
      int ssTicket = 0;
      double ssEntry = 0.0, ssSL = 0.0;
      bool found = FindPending(OP_SELLSTOP, ssTicket, ssEntry, ssSL);

      double spreadDist = FixedSpreadPips * pipSize;
      double offsetDist = MinimumOppositeOffsetPips * pipSize;
      double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
      double targetSSSL    = NormPrice(targetSSEntry + InitialSLPips * pipSize);

      if(found && ssTicket > 0) {
         if(targetSSEntry > ssEntry + (TrailingStepPips * pipSize) && (bid - targetSSEntry) >= stopLevel) {
            if(!OrderModify(ssTicket, targetSSEntry, targetSSSL, 0.0, 0, clrNONE)) {
               Print("[ScalperStar] Modify SellStop gagal. Error: ", GetLastError());
            }
         }
      } else {
         if(!IsSpreadValid(spreadPips)) return;
         if((bid - targetSSEntry) >= stopLevel) {
            int t = OrderSend(Symbol(), OP_SELLSTOP, GetValidLot(), targetSSEntry, MaxSlippagePoints, targetSSSL, 0.0, "Reversal SellStop", MagicNumber, 0, clrNONE);
            if(t < 0) Print("[ScalperStar] Reversal SellStop gagal. Error: ", GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
void ManageSellActive(double ask, double bid, double spreadPips) {
   int posTicket = 0;
   double openPrice = 0.0, currentSL = 0.0, currentTP = 0.0;

   if(!FindPosition(OP_SELL, posTicket, openPrice, currentSL, currentTP)) return;
   if(posTicket == 0) return;

   double stopLevel = GetStopLevel();

   if((openPrice - ask) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(ask + TrailingDistancePips * pipSize);
      if((currentSL == 0.0 || newSL < currentSL - (TrailingStepPips * pipSize)) && (newSL - ask) >= stopLevel) {
         if(OrderModify(posTicket, openPrice, newSL, currentTP, 0, clrNONE)) {
            Print("[ScalperStar] TRAILING ACTIVATED - SL UPDATED");
         } else {
            Print("[ScalperStar] Trailing SELL gagal. Error: ", GetLastError());
         }
      }
   }

   if(TradingMode == TMODE_2) {
      int bsTicket = 0;
      double bsEntry = 0.0, bsSL = 0.0;
      bool found = FindPending(OP_BUYSTOP, bsTicket, bsEntry, bsSL);

      double spreadDist = FixedSpreadPips * pipSize;
      double offsetDist = MinimumOppositeOffsetPips * pipSize;
      double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
      double targetBSSL    = NormPrice(targetBSEntry - InitialSLPips * pipSize);

      if(found && bsTicket > 0) {
         if(targetBSEntry < bsEntry - (TrailingStepPips * pipSize) && (targetBSEntry - ask) >= stopLevel) {
            if(!OrderModify(bsTicket, targetBSEntry, targetBSSL, 0.0, 0, clrNONE)) {
               Print("[ScalperStar] Modify BuyStop gagal. Error: ", GetLastError());
            }
         }
      } else {
         if(!IsSpreadValid(spreadPips)) return;
         if((targetBSEntry - ask) >= stopLevel) {
            int t = OrderSend(Symbol(), OP_BUYSTOP, GetValidLot(), targetBSEntry, MaxSlippagePoints, targetBSSL, 0.0, "Reversal BuyStop", MagicNumber, 0, clrNONE);
            if(t < 0) Print("[ScalperStar] Reversal BuyStop gagal. Error: ", GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
void DeleteOppositePending(int oppositeType) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      if(OrderType() == oppositeType) {
         int ticket = OrderTicket();
         if(OrderDelete(ticket)) {
            Print("[ScalperStar] PENDING OPPOSITE DELETED");
         } else {
            Print("[ScalperStar] Gagal hapus pending #", ticket, ". Error: ", GetLastError());
         }
      }
   }
}

void DeleteAllPending() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      if(OrderType() > OP_SELL) {   // hanya pending order (tipe 2..5)
         int ticket = OrderTicket();
         if(!OrderDelete(ticket)) {
            Print("[ScalperStar] Gagal hapus pending #", ticket, ". Error: ", GetLastError());
         }
      }
   }
}

void CloseAllPositions() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsOurOrder()) continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL) continue;

      int ticket = OrderTicket();
      double lots = OrderLots();
      RefreshRates();
      double price = (type == OP_BUY) ? Bid : Ask;
      if(!OrderClose(ticket, lots, NormPrice(price), MaxSlippagePoints, clrNONE)) {
         Print("[ScalperStar] Gagal close #", ticket, ". Error: ", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
