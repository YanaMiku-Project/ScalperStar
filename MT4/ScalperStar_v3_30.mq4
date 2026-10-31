#property copyright "YanaMiku"
#property link      "t.me/YanaMiku"
#property version   "3.30"
#property strict

enum ENUM_TRADING_MODE {
   MODE_1 = 1,
   MODE_2 = 2
};

enum ENUM_LOT_MODE {
   LOT_FIXED = 0,
   LOT_AUTO  = 1
};

enum ENUM_EA_STATE {
   STATE_IDLE,
   STATE_INITIAL_PENDING,
   STATE_BUY_ACTIVE,
   STATE_SELL_ACTIVE,
   STATE_RESET
};

input ENUM_TRADING_MODE TradingMode = MODE_1;
input ENUM_LOT_MODE LotMode = LOT_FIXED;
input double FixedLot = 0.01;
input double AutoLotRiskPercent = 1.0;
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
int            volDigits = 2;
int            eaDigits = 0;

// Pengganti OnTradeTransaction (tidak ada di MT4): pelacakan jumlah posisi
int            prevBuyCount = 0;
int            prevSellCount = 0;
bool           countsInitialized = false;

int OnInit() {
   SymbolSelect(Symbol(), true);

   eaDigits = Digits;
   pipSize = CalculatePipSize();

   minVolume = MarketInfo(Symbol(), MODE_MINLOT);
   maxVolume = MarketInfo(Symbol(), MODE_MAXLOT);
   volStep   = MarketInfo(Symbol(), MODE_LOTSTEP);
   volDigits = CalculateVolumeDigits(volStep);

   string modeText = (TradingMode == MODE_1 ? "MODE 1" : "MODE 2");
   string lotText = (LotMode == LOT_AUTO ? "AUTO LOT " + DoubleToString(AutoLotRiskPercent, 2) + "%" : "FIXED LOT " + DoubleToString(FixedLot, 2));

   Print("[ScalperStar] EA INITIALIZED - ", modeText, " | ", lotText);
   SendTelegramMsg("[ScalperStar] EA STARTED - " + modeText + " | " + lotText);

   countsInitialized = false;
   SyncStateFromTerminal();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("[ScalperStar] EA STOPPED");
}

double CalculatePipSize() {
   double point = Point;
   if(eaDigits == 5 || eaDigits == 3) return point * 10.0;
   return point;
}

int CalculateVolumeDigits(double step) {
   if(step <= 0.0) return 2;
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 0.00000001) {
      s *= 10.0;
      digits++;
   }
   return digits;
}

double NormPrice(double price) {
   return NormalizeDouble(price, eaDigits);
}

double CalculateAutoLot() {
   double equity = AccountEquity();
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   double slDistance = InitialSLPips * pipSize;

   if(equity <= 0.0 || tickValue <= 0.0 || tickSize <= 0.0 || slDistance <= 0.0 || AutoLotRiskPercent <= 0.0) return FixedLot;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return FixedLot;

   double riskMoney = equity * AutoLotRiskPercent / 100.0;
   return riskMoney / lossPerLot;
}

double GetValidLot() {
   double lot = (LotMode == LOT_AUTO) ? CalculateAutoLot() : FixedLot;

   if(volStep > 0.0) {
      lot = MathFloor(lot / volStep + 0.0000001) * volStep;
   }

   if(lot < minVolume && minVolume > 0.0) lot = minVolume;
   if(lot > maxVolume && maxVolume > 0.0) lot = maxVolume;

   return NormalizeDouble(lot, volDigits);
}

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
      Print("[ScalperStar] Telegram Error: ", GetLastError());
   }
}

bool IsTradingSession() {
   if(!UseTradingSession) return true;
   int hour = TimeHour(TimeCurrent());
   if(StartHour <= EndHour) {
      return (hour >= StartHour && hour <= EndHour);
   } else {
      return (hour >= StartHour || hour <= EndHour);
   }
}

bool IsSpreadValid(double currentSpreadPips) {
   if(MaxSpreadPips <= 0.0) return true;
   return (currentSpreadPips <= MaxSpreadPips);
}

void OnTick() {
   double ask = Ask;
   double bid = Bid;

   if(ask <= 0.0 || bid <= 0.0) return;

   if(pipSize <= 0.0 || volStep <= 0.0 || eaDigits <= 0) {
      eaDigits = Digits;
      pipSize = CalculatePipSize();
      minVolume = MarketInfo(Symbol(), MODE_MINLOT);
      maxVolume = MarketInfo(Symbol(), MODE_MAXLOT);
      volStep   = MarketInfo(Symbol(), MODE_LOTSTEP);
      volDigits = CalculateVolumeDigits(volStep);
      if(pipSize <= 0.0 || volStep <= 0.0) return;
   }

   SyncStateFromTerminal();

   RefreshRates();
   ask = Ask;
   bid = Bid;
   if(ask <= 0.0 || bid <= 0.0) return;

   double spreadPips = (ask - bid) / pipSize;

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

// Pengganti OnTradeTransaction: deteksi posisi baru terbuka / tertutup
void ProcessTradeEvents(int buyCount, int sellCount) {
   if(!countsInitialized) {
      prevBuyCount = buyCount;
      prevSellCount = sellCount;
      countsInitialized = true;
      return;
   }

   if(buyCount > prevBuyCount) {
      Print("[ScalperStar] BUY TRIGGERED");
      SendTelegramMsg("[ScalperStar] BUY TRIGGERED");
      currentState = STATE_BUY_ACTIVE;
      if(TradingMode == MODE_1) DeleteOppositePending(OP_SELLSTOP);
   }

   if(sellCount > prevSellCount) {
      Print("[ScalperStar] SELL TRIGGERED");
      SendTelegramMsg("[ScalperStar] SELL TRIGGERED");
      currentState = STATE_SELL_ACTIVE;
      if(TradingMode == MODE_1) DeleteOppositePending(OP_BUYSTOP);
   }

   int closedBuy  = (prevBuyCount  > buyCount)  ? (prevBuyCount  - buyCount)  : 0;
   int closedSell = (prevSellCount > sellCount) ? (prevSellCount - sellCount) : 0;
   int closedTotal = closedBuy + closedSell;
   for(int k = 0; k < closedTotal; k++) {
      Print("[ScalperStar] POSITION CLOSED");
      SendTelegramMsg("[ScalperStar] POSITION CLOSED");
   }

   prevBuyCount = buyCount;
   prevSellCount = sellCount;
}

void SyncStateFromTerminal() {
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;

      int otype = OrderType();
      if(otype == OP_BUY) buyCount++;
      else if(otype == OP_SELL) sellCount++;
      else if(otype == OP_BUYSTOP) buyStopCount++;
      else if(otype == OP_SELLSTOP) sellStopCount++;
   }

   ProcessTradeEvents(buyCount, sellCount);

   if(buyCount > 0 && sellCount > 0) {
      CloseAllPositions();
      currentState = STATE_RESET;
      return;
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

// Kirim pending stop order. Mengembalikan ticket (>0) jika sukses, -1 jika gagal (err berisi kode error)
int PlaceStopOrder(int orderType, double vol, double price, double sl, string comment, int &err) {
   ResetLastError();
   int ticket = OrderSend(Symbol(), orderType, vol, price, MaxSlippagePoints, sl, 0.0, comment, MagicNumber, 0, clrNONE);
   if(ticket < 0) {
      err = GetLastError();
      return -1;
   }
   err = 0;
   return ticket;
}

void PlaceInitialSetup(double ask, double bid) {
   DeleteAllPending();

   double vol = GetValidLot();
   double pointVal = Point;
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * pointVal;
   double minDistance = MathMax(InitialDistancePips * pipSize, stopLevel);

   double buyEntry = NormPrice(ask + minDistance);
   double buySL = NormPrice(buyEntry - InitialSLPips * pipSize);

   double sellEntry = NormPrice(bid - minDistance);
   double sellSL = NormPrice(sellEntry + InitialSLPips * pipSize);

   int bErr = 0, sErr = 0;
   int bTicket = PlaceStopOrder(OP_BUYSTOP, vol, buyEntry, buySL, "Initial BuyStop", bErr);
   int sTicket = PlaceStopOrder(OP_SELLSTOP, vol, sellEntry, sellSL, "Initial SellStop", sErr);

   bool bRes = (bTicket > 0);
   bool sRes = (sTicket > 0);

   if(bRes && sRes) {
      Print("[ScalperStar] BUY STOP PLACED | SELL STOP PLACED | LOT: ", DoubleToString(vol, volDigits), " | EQUITY: ", DoubleToString(AccountEquity(), 2));
      SendTelegramMsg("[ScalperStar] INITIAL PENDING ORDERS PLACED | LOT: " + DoubleToString(vol, volDigits));
      currentState = STATE_INITIAL_PENDING;
   } else {
      Print("[ScalperStar] GAGAL ENTRY! Cek kode error berikut:");
      if(!bRes) Print("BuyStop Error: ", bErr, " | Ask: ", DoubleToString(ask, eaDigits), " | Entry Target: ", DoubleToString(buyEntry, eaDigits));
      if(!sRes) Print("SellStop Error: ", sErr, " | Bid: ", DoubleToString(bid, eaDigits), " | Entry Target: ", DoubleToString(sellEntry, eaDigits));
   }
}

void ManageBuyActive(double ask, double bid, double spreadPips) {
   int posTicket = 0;
   double openPrice = 0.0;
   double currentSL = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == OP_BUY) {
         posTicket = OrderTicket();
         openPrice = OrderOpenPrice();
         currentSL = OrderStopLoss();
         break;
      }
   }

   if(posTicket <= 0) return;

   double pointVal = Point;
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * pointVal;

   if((bid - openPrice) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(bid - TrailingDistancePips * pipSize);
      if(newSL > currentSL + (TrailingStepPips * pipSize) && (bid - newSL) >= stopLevel) {
         if(OrderModify(posTicket, openPrice, newSL, 0.0, 0, clrNONE)) {
            Print("[ScalperStar] TRAILING ACTIVATED - SL UPDATED");
         }
      }
   }

   if(TradingMode == MODE_2) {
      int ssTicket = 0;
      double ssEntry = 0.0;

      for(int j = OrdersTotal() - 1; j >= 0; j--) {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == OP_SELLSTOP) {
            ssTicket = OrderTicket();
            ssEntry = OrderOpenPrice();
            break;
         }
      }

      if(ssTicket > 0) {
         double spreadDist = FixedSpreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;

         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);

         if(targetSSEntry > ssEntry + (TrailingStepPips * pipSize) && (bid - targetSSEntry) >= stopLevel) {
            OrderModify(ssTicket, targetSSEntry, targetSSSL, 0.0, 0, clrNONE);
         }
      } else {
         if(!IsSpreadValid(spreadPips)) return;
         double spreadDist = FixedSpreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetSSEntry = NormPrice(bid - (DynamicPendingDistancePips * pipSize) - spreadDist - offsetDist);
         double targetSSSL = NormPrice(targetSSEntry + InitialSLPips * pipSize);
         if((bid - targetSSEntry) >= stopLevel) {
            int err = 0;
            if(PlaceStopOrder(OP_SELLSTOP, GetValidLot(), targetSSEntry, targetSSSL, "Reversal SellStop", err) < 0) {
               Print("[ScalperStar] Reversal SellStop Error: ", err);
            }
         }
      }
   }
}

void ManageSellActive(double ask, double bid, double spreadPips) {
   int posTicket = 0;
   double openPrice = 0.0;
   double currentSL = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == OP_SELL) {
         posTicket = OrderTicket();
         openPrice = OrderOpenPrice();
         currentSL = OrderStopLoss();
         break;
      }
   }

   if(posTicket <= 0) return;

   double pointVal = Point;
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * pointVal;

   if((openPrice - ask) >= (TrailingStartPips * pipSize)) {
      double newSL = NormPrice(ask + TrailingDistancePips * pipSize);
      if((currentSL == 0.0 || newSL < currentSL - (TrailingStepPips * pipSize)) && (newSL - ask) >= stopLevel) {
         if(OrderModify(posTicket, openPrice, newSL, 0.0, 0, clrNONE)) {
            Print("[ScalperStar] TRAILING ACTIVATED - SL UPDATED");
         }
      }
   }

   if(TradingMode == MODE_2) {
      int bsTicket = 0;
      double bsEntry = 0.0;

      for(int j = OrdersTotal() - 1; j >= 0; j--) {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == OP_BUYSTOP) {
            bsTicket = OrderTicket();
            bsEntry = OrderOpenPrice();
            break;
         }
      }

      if(bsTicket > 0) {
         double spreadDist = FixedSpreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;

         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);

         if(targetBSEntry < bsEntry - (TrailingStepPips * pipSize) && (targetBSEntry - ask) >= stopLevel) {
            OrderModify(bsTicket, targetBSEntry, targetBSSL, 0.0, 0, clrNONE);
         }
      } else {
         if(!IsSpreadValid(spreadPips)) return;
         double spreadDist = FixedSpreadPips * pipSize;
         double offsetDist = MinimumOppositeOffsetPips * pipSize;
         double targetBSEntry = NormPrice(ask + (DynamicPendingDistancePips * pipSize) + spreadDist + offsetDist);
         double targetBSSL = NormPrice(targetBSEntry - InitialSLPips * pipSize);
         if((targetBSEntry - ask) >= stopLevel) {
            int err = 0;
            if(PlaceStopOrder(OP_BUYSTOP, GetValidLot(), targetBSEntry, targetBSSL, "Reversal BuyStop", err) < 0) {
               Print("[ScalperStar] Reversal BuyStop Error: ", err);
            }
         }
      }
   }
}

void DeleteOppositePending(int oppositeType) {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber) {
         if(OrderType() == oppositeType) {
            if(OrderDelete(OrderTicket())) {
               Print("[ScalperStar] PENDING OPPOSITE DELETED");
            }
         }
      }
   }
}

void DeleteAllPending() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() > OP_SELL) {
         OrderDelete(OrderTicket());
      }
   }
}

void CloseAllPositions() {
   RefreshRates();
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber) {
         int otype = OrderType();
         if(otype == OP_BUY || otype == OP_SELL) {
            double closePrice = (otype == OP_BUY) ? Bid : Ask;
            if(!OrderClose(OrderTicket(), OrderLots(), NormPrice(closePrice), MaxSlippagePoints, clrNONE)) {
               Print("[ScalperStar] Close Error: ", GetLastError());
            }
         }
      }
   }
}
