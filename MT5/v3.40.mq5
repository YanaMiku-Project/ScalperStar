//+------------------------------------------------------------------+
//|                                                  ScalperStar.mq5 |
//|                       Stop-order scalper: Mode 1 / Mode 2        |
//+------------------------------------------------------------------+
#property copyright "ScalperStar"
#property version   "3.40"
#property description "ScalperStar - Buy Stop / Sell Stop scalper with trailing (Mode 1 & Mode 2 reversal)"

#include <Trade\Trade.mqh>

#define PFX "ScalperStar_"

//--- enums
enum ENUM_SS_MODE    { MODE_1 = 1, MODE_2 = 2 };
enum ENUM_SS_LOTMODE { FIXED_LOT = 0, EQUITY_LOT = 1 };
enum ENUM_SS_STATE   { IDLE = 0, PENDING = 1, IN_BUY = 2, IN_SELL = 3 };

//--- inputs
input ENUM_SS_MODE    Mode               = MODE_1;     // Mode
input double          DistancePips       = 10.0;       // Jarak pending dari Bid/Ask (pips)
input double          SLPips             = 10.0;       // Stop Loss (pips)
input double          TrailPips          = 10.0;       // Trailing (pips)
input ENUM_SS_LOTMODE LotMode            = FIXED_LOT;  // Mode lot
input double          FixedLot           = 0.01;       // Lot dasar
input double          EquityPerLot       = 1000.0;     // Setiap kelipatan Equity ini lot naik
input double          LotStep            = 0.01;       // Kenaikan lot
input double          MaxLot             = 100.0;      // Lot maksimum
input long            MagicNumber        = 20260101;   // Magic Number
input int             MaxSpreadPoints    = 0;          // Maks spread (point), 0 = nonaktif
input bool            SpreadCompensation = true;       // Kompensasi spread / penutup celah (Mode 2)
input int             Slippage           = 10;         // Slippage (point)

//--- snapshot of own positions / pending orders
struct SSnap
  {
   int               nPos;
   ENUM_POSITION_TYPE ptype;
   ulong             pticket;
   double            psl;
   double            ptp;
   double            pvol;
   double            floating;
   int               nBuyStop;
   int               nSellStop;
   int               nOther;
   ulong             tBuyStop;
   ulong             tSellStop;
   double            pBuyStop;
   double            pSellStop;
  };

//--- globals
CTrade             trade;
double             g_pip      = 0.0;
ENUM_SS_STATE      g_state    = IDLE;
double             g_cycleLot = 0.0;
double             g_chainLot = 0.0;
bool               g_chain    = false;
ENUM_POSITION_TYPE g_lastType = POSITION_TYPE_BUY;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool RetOK(const uint rc)
  {
   return(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
          rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_NO_CHANGES);
  }

// minimum distance (stops/freeze level + 1 point margin)
double StopsDist()
  {
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fr = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return((double)MathMax(sl, fr) * _Point + _Point);
  }

double FreezeDist()
  {
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point);
  }

double NormLot(double lot)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   double cap = vmax;
   if(MaxLot > 0.0 && MaxLot < cap)
      cap = MaxLot;
   if(lot > cap)
      lot = cap;
   lot = MathFloor(lot / step + 1e-8) * step;
   if(lot < vmin)
      lot = vmin;
   return(NormalizeDouble(lot, 8));
  }

double CalcLot()
  {
   double lot = FixedLot;
   if(LotMode == EQUITY_LOT && EquityPerLot > 0.0)
     {
      double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
      double mult = MathFloor(eq / EquityPerLot - 1.0);
      if(mult > 0.0)
         lot = FixedLot + mult * LotStep;
     }
   return(NormLot(lot));
  }

bool SpreadOK()
  {
   if(MaxSpreadPoints <= 0)
      return(true);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int sp = (int)MathRound((ask - bid) / _Point);
   return(sp <= MaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Scan positions and pending orders (symbol + magic)               |
//+------------------------------------------------------------------+
void Scan(SSnap &s)
  {
   s.nPos = 0;
   s.ptype = POSITION_TYPE_BUY;
   s.pticket = 0;
   s.psl = 0.0;
   s.ptp = 0.0;
   s.pvol = 0.0;
   s.floating = 0.0;
   s.nBuyStop = 0;
   s.nSellStop = 0;
   s.nOther = 0;
   s.tBuyStop = 0;
   s.tSellStop = 0;
   s.pBuyStop = 0.0;
   s.pSellStop = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      s.floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      s.nPos++;
      if(s.pticket == 0 || t < s.pticket)
        {
         s.pticket = t;
         s.ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         s.psl = PositionGetDouble(POSITION_SL);
         s.ptp = PositionGetDouble(POSITION_TP);
         s.pvol = PositionGetDouble(POSITION_VOLUME);
        }
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_STOP)
        {
         s.nBuyStop++;
         s.tBuyStop = t;
         s.pBuyStop = OrderGetDouble(ORDER_PRICE_OPEN);
        }
      else
         if(ot == ORDER_TYPE_SELL_STOP)
           {
            s.nSellStop++;
            s.tSellStop = t;
            s.pSellStop = OrderGetDouble(ORDER_PRICE_OPEN);
           }
         else
            s.nOther++;
     }
  }

//+------------------------------------------------------------------+
//| Trade operations                                                 |
//+------------------------------------------------------------------+
bool DeleteOrder(const ulong ticket)
  {
   for(int a = 0; a < 3; a++)
     {
      if(trade.OrderDelete(ticket) && RetOK(trade.ResultRetcode()))
         return(true);
      if(!OrderSelect(ticket))
         return(true); // already gone (triggered or deleted)
     }
   return(false);
  }

bool DeleteAllPendings()
  {
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      if(!DeleteOrder(t))
         ok = false;
     }
   return(ok);
  }

void CloseExtras(const SSnap &s)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(t == s.pticket)
         continue;
      if(trade.PositionClose(t))
         continue;
     }
   DeleteAllPendings();
  }

bool PlaceStop(const ENUM_ORDER_TYPE type, const double price, const double sl, const double lot)
  {
   bool ok = false;
   if(type == ORDER_TYPE_BUY_STOP)
      ok = trade.BuyStop(lot, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "ScalperStar");
   else
      ok = trade.SellStop(lot, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "ScalperStar");
   return(ok && RetOK(trade.ResultRetcode()));
  }

bool ModifySL(const ulong ticket, const double sl, const double tp)
  {
   return(trade.PositionModify(ticket, sl, tp) && RetOK(trade.ResultRetcode()));
  }

//--- start a new cycle: Buy Stop + Sell Stop
bool StartCycle()
  {
   if(!SpreadOK())
      return(false);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = StopsDist();
   double d    = MathMax(DistancePips * g_pip, minD);
   double sd   = MathMax(SLPips * g_pip, minD);

   g_cycleLot = CalcLot();
   double bp = NormalizeDouble(ask + d, _Digits);
   double sp = NormalizeDouble(bid - d, _Digits);

   if(!PlaceStop(ORDER_TYPE_BUY_STOP, bp, NormalizeDouble(bp - sd, _Digits), g_cycleLot))
      return(false);
   if(!PlaceStop(ORDER_TYPE_SELL_STOP, sp, NormalizeDouble(sp + sd, _Digits), g_cycleLot))
      return(false);
   return(true);
  }

//--- one-direction trailing of the open position
void ManageTrail(const SSnap &s)
  {
   double minD  = StopsDist();
   double frz   = FreezeDist();
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trail = MathMax(TrailPips * g_pip, minD);

   if(s.ptype == POSITION_TYPE_BUY)
     {
      if(frz > 0.0 && s.psl > 0.0 && (bid - s.psl) <= frz)
         return;
      double nsl = NormalizeDouble(bid - trail, _Digits);
      if(nsl >= bid)
         return;
      if(s.psl > 0.0 && (nsl - s.psl) < _Point * 0.9)
         return;
      ModifySL(s.pticket, nsl, s.ptp);
     }
   else
     {
      if(frz > 0.0 && s.psl > 0.0 && (s.psl - ask) <= frz)
         return;
      double nsl = NormalizeDouble(ask + trail, _Digits);
      if(nsl <= ask)
         return;
      if(s.psl > 0.0 && (s.psl - nsl) < _Point * 0.9)
         return;
      ModifySL(s.pticket, nsl, s.ptp);
     }
  }

//+------------------------------------------------------------------+
//| MODE 1                                                           |
//+------------------------------------------------------------------+
void RunMode1(const SSnap &s)
  {
   if(s.nPos > 1)
     {
      CloseExtras(s);
      return;
     }
   if(s.nPos == 1)
     {
      // fast delete of opposite pending
      if(s.nBuyStop + s.nSellStop + s.nOther > 0)
         DeleteAllPendings();
      ManageTrail(s);
      return;
     }
   // no position
   if(s.nBuyStop == 1 && s.nSellStop == 1 && s.nOther == 0)
      return; // PENDING
   if(s.nBuyStop + s.nSellStop + s.nOther > 0)
     {
      DeleteAllPendings(); // abnormal -> restart
      return;
     }
   StartCycle();
  }

//+------------------------------------------------------------------+
//| MODE 2                                                           |
//+------------------------------------------------------------------+
bool LastCloseWasSL()
  {
   datetime to = TimeCurrent();
   if(!HistorySelect(to - 86400 * 3, to + 60))
      return(false);
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0)
         continue;
      if(HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(dt, DEAL_MAGIC) != MagicNumber)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY)
         continue;
      ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)HistoryDealGetInteger(dt, DEAL_REASON);
      return(rs == DEAL_REASON_SL);
     }
   return(false);
  }

// keep the opposite pending glued to the position SL
void SyncOpposite(const SSnap &s)
  {
   bool isBuy = (s.ptype == POSITION_TYPE_BUY);
   int  nOpp  = isBuy ? s.nSellStop : s.nBuyStop;
   int  nBad  = isBuy ? (s.nBuyStop + s.nOther) : (s.nSellStop + s.nOther);

   if(nBad > 0 || nOpp > 1)
     {
      DeleteAllPendings(); // abnormal -> clean, re-place next tick
      return;
     }
   if(s.psl <= 0.0)
      return;

   double minD = StopsDist();
   double sd   = MathMax(SLPips * g_pip, minD);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Position SL and the opposite stop share the same price basis
   // (Buy SL & Sell Stop -> Bid, Sell SL & Buy Stop -> Ask) => exact SL price.
   double P = NormalizeDouble(s.psl, _Digits);
   bool clamped = false;
   if(SpreadCompensation)
     {
      if(isBuy)
        {
         double lim = NormalizeDouble(bid - minD, _Digits);
         if(P > lim)
           {
            P = lim;
            clamped = true;
           }
        }
      else
        {
         double lim = NormalizeDouble(ask + minD, _Digits);
         if(P < lim)
           {
            P = lim;
            clamped = true;
           }
        }
     }
   double pendSL = isBuy ? NormalizeDouble(P + sd, _Digits) : NormalizeDouble(P - sd, _Digits);

   if(nOpp == 0)
     {
      double lot = NormLot(s.pvol);
      g_chainLot = lot;
      PlaceStop(isBuy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP, P, pendSL, lot);
      return;
     }

   ulong  tk  = isBuy ? s.tSellStop : s.tBuyStop;
   double cur = isBuy ? s.pSellStop : s.pBuyStop;

   if(MathAbs(cur - s.psl) < _Point * 0.9)
      return; // already exactly at SL
   if(clamped)
     {
      if(isBuy && P <= cur + _Point * 0.9)
         return;
      if(!isBuy && P >= cur - _Point * 0.9)
         return;
     }
   if(MathAbs(cur - P) < _Point * 0.9)
      return;

   if(trade.OrderModify(tk, P, pendSL, 0.0, ORDER_TIME_GTC, 0, 0.0))
      return;
  }

// SL was hit but the opposite pending did not trigger: open reverse at market
void ReverseByMarket(const SSnap &s)
  {
   bool wasBuy = (g_lastType == POSITION_TYPE_BUY);
   if((wasBuy && s.nSellStop != 1) || (!wasBuy && s.nBuyStop != 1))
     {
      DeleteAllPendings();
      g_chain = false;
      return;
     }
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // pending is about to trigger by itself -> wait
   if(wasBuy && bid <= s.pSellStop + _Point * 0.5)
      return;
   if(!wasBuy && ask >= s.pBuyStop - _Point * 0.5)
      return;

   ulong tk = wasBuy ? s.tSellStop : s.tBuyStop;
   if(!DeleteOrder(tk))
      return;

   SSnap t;
   Scan(t);
   if(t.nPos > 0)
      return; // pending triggered in the meantime

   double minD = StopsDist();
   double sd   = MathMax(SLPips * g_pip, minD);
   double lot  = NormLot(g_chainLot > 0.0 ? g_chainLot : CalcLot());
   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(wasBuy)
     {
      double sl = NormalizeDouble(MathMax(bid + sd, ask + minD), _Digits);
      if(trade.Sell(lot, _Symbol, 0.0, sl, 0.0, "ScalperStar"))
         return;
     }
   else
     {
      double sl = NormalizeDouble(MathMin(ask - sd, bid - minD), _Digits);
      if(trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "ScalperStar"))
         return;
     }
  }

void RunMode2(const SSnap &s)
  {
   if(s.nPos > 1)
     {
      CloseExtras(s);
      return;
     }
   if(s.nPos == 1)
     {
      g_chain = true;
      g_lastType = s.ptype;
      g_chainLot = s.pvol;
      ManageTrail(s);
      SSnap t;
      Scan(t);
      if(t.nPos != 1)
         return;
      SyncOpposite(t);
      return;
     }

   // no position
   int np = s.nBuyStop + s.nSellStop + s.nOther;
   if(np == 0)
     {
      g_chain = false;
      StartCycle();
      return;
     }
   if(s.nBuyStop == 1 && s.nSellStop == 1 && s.nOther == 0)
     {
      g_chain = false; // fresh cycle waiting
      return;
     }
   if(g_chain && SpreadCompensation && np == 1 && s.nOther == 0 && LastCloseWasSL())
     {
      ReverseByMarket(s);
      return;
     }
   // abnormal -> clean and restart
   DeleteAllPendings();
   g_chain = false;
  }

//+------------------------------------------------------------------+
//| Main logic                                                       |
//+------------------------------------------------------------------+
void RunLogic()
  {
   SSnap s;
   Scan(s);
   if(Mode == MODE_1)
      RunMode1(s);
   else
      RunMode2(s);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void MakeRect(const string n, const int x, const int y, const int w, const int h,
              const color bg, const color border)
  {
   string name = PFX + n;
   ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void MakeLbl(const string n, const int x, const int y, const string txt,
             const color clr, const int fs, const string font)
  {
   string name = PFX + n;
   ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fs);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void SetVal(const int idx, const string txt, const color clr)
  {
   string name = PFX + "v" + IntegerToString(idx);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void CreatePanel()
  {
   int x = 10, y = 22, w = 230, h = 206;
   MakeRect("bg", x, y, w, h, C'10,15,40', clrDeepSkyBlue);
   MakeRect("hd", x, y, w, 26, C'255,140,0', C'255,140,0');
   MakeLbl("title", x + 10, y + 4, "ScalperStar", clrWhite, 12, "Arial Black");
   string names[8] = {"Mode", "Spread", "Status", "Lot", "Lot Mode", "Equity", "Balance", "Floating P/L"};
   for(int i = 0; i < 8; i++)
     {
      int yy = y + 36 + i * 20;
      MakeLbl("k" + IntegerToString(i), x + 10, yy, names[i] + ":", clrSilver, 9, "Arial");
      MakeLbl("v" + IntegerToString(i), x + 100, yy, "-", clrWhite, 9, "Arial");
     }
  }

void UpdatePanel()
  {
   SSnap s;
   Scan(s);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    spPts  = (int)MathRound((ask - bid) / _Point);
   double spPips = (g_pip > 0.0) ? (ask - bid) / g_pip : 0.0;

   color sc = clrLime;
   if(MaxSpreadPoints > 0)
     {
      if(spPts <= MaxSpreadPoints / 2)
         sc = clrLime;
      else
         if(spPts <= MaxSpreadPoints)
            sc = clrYellow;
         else
            sc = clrRed;
     }
   else
     {
      if(spPips <= 1.5)
         sc = clrLime;
      else
         if(spPips <= 3.0)
            sc = clrYellow;
         else
            sc = clrRed;
     }

   string stTxt = "IDLE";
   color  stClr = clrSilver;
   double lot   = 0.0;
   int    np    = s.nBuyStop + s.nSellStop + s.nOther;

   if(s.nPos >= 1)
     {
      lot = s.pvol;
      if(s.ptype == POSITION_TYPE_BUY)
        {
         g_state = IN_BUY;
         stTxt = "BUY";
         stClr = clrLime;
        }
      else
        {
         g_state = IN_SELL;
         stTxt = "SELL";
         stClr = clrTomato;
        }
     }
   else
      if(np > 0)
        {
         g_state = PENDING;
         stTxt = "PENDING";
         stClr = clrYellow;
         lot = (g_cycleLot > 0.0) ? g_cycleLot : CalcLot();
        }
      else
        {
         g_state = IDLE;
         lot = CalcLot();
        }

   color fc = clrWhite;
   if(s.floating > 0.0)
      fc = clrLime;
   else
      if(s.floating < 0.0)
         fc = clrRed;

   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   SetVal(0, (Mode == MODE_1) ? "Mode 1" : "Mode 2", clrAqua);
   SetVal(1, IntegerToString(spPts) + " pt / " + DoubleToString(spPips, 1) + " pip", sc);
   SetVal(2, stTxt, stClr);
   SetVal(3, DoubleToString(lot, 2), clrWhite);
   SetVal(4, (LotMode == FIXED_LOT) ? "FIXED_LOT" : "EQUITY_LOT", clrOrange);
   SetVal(5, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " " + cur, clrWhite);
   SetVal(6, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + cur, clrWhite);
   SetVal(7, DoubleToString(s.floating, 2) + " " + cur, fc);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(DistancePips <= 0.0 || SLPips <= 0.0 || TrailPips <= 0.0 || FixedLot <= 0.0)
     {
      Print("ScalperStar: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_pip = (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   CreatePanel();
   EventSetTimer(1);
   UpdatePanel();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
  }

void OnTick()
  {
   RunLogic();
   UpdatePanel();
  }

void OnTimer()
  {
   UpdatePanel();
  }

// Mode 1: react immediately on fills to delete the opposite pending asap
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(Mode == MODE_1 && trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.symbol == _Symbol)
      RunLogic();
  }
//+------------------------------------------------------------------+
