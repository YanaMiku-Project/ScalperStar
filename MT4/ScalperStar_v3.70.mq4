//+------------------------------------------------------------------+
//|                                                  ScalperStar.mq4 |
//|        MT4 port of ScalperStar v3.70 (MT5)                       |
//+------------------------------------------------------------------+
#property copyright "ScalperStar"
#property version   "3.70"
#property description "ScalperStar - Buy Stop / Sell Stop scalper with trailing (Mode 1 & Mode 2 reversal), MT4 port"
#property strict

const string PFX = "ScalperStar_";

//--- enums (prefixed to avoid name clashes)
enum ENUM_SS_MODE    { SS_MODE_1 = 1,       // Mode 1 (OCO breakout)
                       SS_MODE_2 = 2 };     // Mode 2 (reversal chain)
enum ENUM_SS_LOTMODE { SS_FIXED_LOT = 0,    // Fixed lot
                       SS_EQUITY_LOT = 1 }; // Equity based lot
enum ENUM_SS_STATE   { SS_IDLE = 0, SS_PENDING = 1, SS_IN_BUY = 2, SS_IN_SELL = 3 };

//--- MT4 error codes (own constants, no dependency on stderror.mqh)
#define SS_E_NO_RESULT          1
#define SS_E_TOO_FREQUENT       8
#define SS_E_ACCOUNT_DISABLED   64
#define SS_E_TRADE_TIMEOUT      128
#define SS_E_INVALID_STOPS      130
#define SS_E_INVALID_VOLUME     131
#define SS_E_MARKET_CLOSED      132
#define SS_E_TRADE_DISABLED     133
#define SS_E_NO_MONEY           134
#define SS_E_PRICE_CHANGED      135
#define SS_E_OFF_QUOTES         136
#define SS_E_BROKER_BUSY        137
#define SS_E_REQUOTE            138
#define SS_E_LONG_ONLY          140
#define SS_E_TOO_MANY_REQ       141
#define SS_E_MODIFY_DENIED      145
#define SS_E_CTX_BUSY           146
#define SS_E_EXPIRY_DENIED      147
#define SS_E_TOO_MANY_ORDERS    148
#define SS_E_HEDGE_PROHIBITED   149
#define SS_E_FIFO               150
#define SS_E_NOT_ALLOWED        4109
#define SS_E_LONGS_NOT_ALLOWED  4110
#define SS_E_SHORTS_NOT_ALLOWED 4111

//--- inputs
input group "=== Strategi ==="
input ENUM_SS_MODE    Mode               = SS_MODE_1;     // Mode
input double          DistancePips       = 10.0;          // Jarak pending dari Bid/Ask (pips)
input double          SLPips             = 10.0;          // Stop Loss (pips)
input double          TrailPips          = 10.0;          // Trailing (pips)
input double          TPPips             = 0.0;           // Take Profit (pips), 0 = tanpa TP
input int             PointsPerPip       = 0;             // Point per 1 pip, 0 = otomatis (XAU/indeks: isi manual!)
input bool            SpreadCompensation = true;          // Mode 2: tutup celah dengan market order bila pending tidak terpicu
input int             Slippage           = 10;            // Slippage (point)

input group "=== Lot & Margin ==="
input ENUM_SS_LOTMODE LotMode            = SS_FIXED_LOT;  // Mode lot
input double          FixedLot           = 0.01;          // Lot dasar
input double          EquityPerLot       = 1000.0;        // Setiap kelipatan Equity ini lot naik
input double          LotStep            = 0.01;          // Kenaikan lot
input double          MaxLot             = 100.0;         // Lot maksimum
input bool            ReverseLotRecalc   = true;          // Mode 2: hitung ulang lot di tiap reversal
input int             MagicNumber        = 20260101;      // Magic Number

input group "=== Eksekusi aman ==="
input int             StopsBufferPoints  = 3;             // Buffer di atas stops/freeze level (point)
input double          MinDistSpreadMult  = 3.0;           // Jarak pending minimum = N x spread
input int             CooldownMs         = 2000;          // Cooldown dasar setelah request gagal (ms)
input int             ModifyIntervalMs   = 300;           // Jeda minimum antar modify trailing/pending (ms)
input int             TrailStepPoints    = 5;             // Langkah minimum trailing (point)
input int             GraceMs            = 1500;          // Tahan cleanup saat 2 posisi muncul (ms)
input int             HistoryWaitMs      = 3000;          // Tunggu history order terupdate (ms)
input int             PendingExpiryMin   = 60;            // Expiry pending (menit), 0 = GTC
input int             TimerMs            = 250;           // Interval timer pengganti OnTradeTransaction (ms)

//--- snapshot of own positions / pending orders
struct SSnap
  {
   int               nPos;
   int               ptype;       // OP_BUY / OP_SELL of NEWEST position
   int               pticket;     // NEWEST position ticket
   double            popen;
   double            psl;
   double            ptp;
   double            pvol;
   double            floating;
   int               tBest;       // position with best floating P/L
   int               nBuyStop;
   int               nSellStop;
   int               nOther;
   int               tBuyStop;
   int               tSellStop;
   double            pBuyStop;
   double            pSellStop;
   datetime          expBuy;
   datetime          expSell;
  };

//--- globals
bool               g_tester     = false;
bool               g_panelOn    = true;
double             g_pip        = 0.0;
ENUM_SS_STATE      g_state      = SS_IDLE;
double             g_cycleLot   = 0.0;
bool               g_noExpiry   = false;   // broker denied expiration -> use GTC

// chain (Mode 2)
bool               g_chain      = false;
int                g_lastType   = OP_BUY;
int                g_curTicket  = 0;
int                g_curType    = OP_BUY;
int                g_lastTicket = 0;
int                g_revCount   = 0;
double             g_chainLot   = 0.0;
ulong              g_waitSince  = 0;
ulong              g_extraSince = 0;

// request throttling
ulong              g_failUntil    = 0;
int                g_failCount    = 0;
ulong              g_modFailUntil = 0;
ulong              g_lastModMs    = 0;
bool               g_reqSent      = false;
ulong              g_delFailUntil = 0;
int                g_slChecked    = 0;
int                g_lastErr      = 0;

// risk
datetime           g_day        = 0;
double             g_dayPL      = 0.0;
double             g_floating   = 0.0;
ulong              g_riskMs     = 0;

// misc
ulong              g_panelMs    = 0;
bool               g_inLogic    = false;
ulong              g_warnMs     = 0;
string             g_lastWarn   = "";

//+------------------------------------------------------------------+
//| Time helpers (tick-time in tester, so throttles behave the same) |
//+------------------------------------------------------------------+
ulong NowMs()
  {
   if(g_tester)
      return((ulong)TimeCurrent() * 1000);
   return((ulong)(GetMicrosecondCount() / 1000) + 1000);
  }

void Warn(const string txt)
  {
   ulong now = NowMs();
   if(txt == g_lastWarn && now - g_warnMs < 60000)
      return;
   g_lastWarn = txt;
   g_warnMs   = now;
   Print("ScalperStar: ", txt);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool Cooling()
  {
   return(NowMs() < g_failUntil);
  }

void Cool(const ulong ms)
  {
   ulong u = NowMs() + ms;
   if(u > g_failUntil)
      g_failUntil = u;
  }

// failure of an order/close request -> cooldown with back-off
void OnFail(const string ctx, const int err)
  {
   g_lastErr = err;
   g_failCount++;
   int base = (int)MathMax((double)CooldownMs, 200.0);
   int mul  = (int)MathMin((double)g_failCount, 5.0);
   ulong cd = (ulong)base * (ulong)mul;
   if(err == SS_E_NO_MONEY || err == SS_E_TRADE_DISABLED || err == SS_E_MARKET_CLOSED ||
      err == SS_E_NOT_ALLOWED || err == SS_E_LONG_ONLY || err == SS_E_LONGS_NOT_ALLOWED ||
      err == SS_E_SHORTS_NOT_ALLOWED || err == SS_E_TOO_MANY_ORDERS || err == SS_E_INVALID_VOLUME ||
      err == SS_E_HEDGE_PROHIBITED || err == SS_E_FIFO || err == SS_E_ACCOUNT_DISABLED)
     {
      if(cd < 30000)
         cd = 30000;
     }
   else
      if((err == SS_E_TOO_MANY_REQ || err == SS_E_TOO_FREQUENT) && cd < 5000)
         cd = 5000;
   Cool(cd);
   Print(StringFormat("ScalperStar: %s failed err=%d, cooldown %I64u ms", ctx, err, cd));
  }

void ModFail(const int err)
  {
   g_lastErr = err;
   ulong cd = (err == SS_E_MODIFY_DENIED || err == SS_E_TOO_MANY_REQ || err == SS_E_TOO_FREQUENT) ? 3000 : 1000;
   g_modFailUntil = NowMs() + cd;
   Warn(StringFormat("modify failed err=%d", err));
  }

bool ModDue()
  {
   ulong now = NowMs();
   if(now < g_modFailUntil)
      return(false);
   return(now - g_lastModMs >= (ulong)MathMax((double)ModifyIntervalMs, 0.0));
  }

// wait briefly if another EA holds the trade context
void WaitCtx()
  {
   if(g_tester)
      return;
   for(int i = 0; i < 5 && IsTradeContextBusy() && !IsStopped(); i++)
      Sleep(50);
  }

// minimum distance: max(stops, freeze) + buffer
double StopsDist()
  {
   double sl = MarketInfo(_Symbol, MODE_STOPLEVEL);
   double fr = MarketInfo(_Symbol, MODE_FREEZELEVEL);
   double mx = MathMax(sl, fr);
   return((mx + MathMax((double)StopsBufferPoints, 1.0)) * _Point);
  }

double FreezeDist()
  {
   return(MarketInfo(_Symbol, MODE_FREEZELEVEL) * _Point);
  }

double NormLot(double lot)
  {
   double step = MarketInfo(_Symbol, MODE_LOTSTEP);
   double vmin = MarketInfo(_Symbol, MODE_MINLOT);
   double vmax = MarketInfo(_Symbol, MODE_MAXLOT);
   if(step <= 0.0)
      step = 0.01;
   double cap = vmax;
   if(cap <= 0.0)
      cap = 100000.0;
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
   if(LotMode == SS_EQUITY_LOT && EquityPerLot > 0.0)
     {
      double eq   = AccountEquity();
      double mult = MathFloor(eq / EquityPerLot - 1.0);
      if(mult > 0.0)
         lot = FixedLot + mult * LotStep;
     }
   return(NormLot(lot));
  }

// lot reduced to what margin allows; 0 = cannot trade
// sides: how many such positions could be open at the same time
double FitLot(const double lotWanted, const int sides)
  {
   double want = NormLot(lotWanted);
   double mpl  = MarketInfo(_Symbol, MODE_MARGINREQUIRED);   // margin per 1 lot
   if(mpl <= 0.0)
      return(want);
   double room = AccountFreeMargin();
   if(room <= 0.0)
      return(0.0);
   double maxLot = room / (mpl * (double)MathMax(sides, 1));
   double lot    = MathMin(want, maxLot);
   double step   = MarketInfo(_Symbol, MODE_LOTSTEP);
   double vmin   = MarketInfo(_Symbol, MODE_MINLOT);
   if(step <= 0.0)
      step = 0.01;
   lot = MathFloor(lot / step + 1e-8) * step;
   if(lot < vmin - 1e-12)
      return(0.0);
   if(lot < want - 1e-12)
      Warn(StringFormat("lot reduced %.2f -> %.2f by margin limit", want, lot));
   return(NormalizeDouble(lot, 8));
  }

bool SpreadOK()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
      return(false);
   return(true);
  }

// trading permissions
bool CanTradeNow(string &why)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     { why = "AutoTrading terminal OFF"; return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { why = "EA trading not allowed"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { why = "Account trading disabled"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { why = "Experts disabled for account"; return(false); }
   if(!g_tester)
     {
      if(!IsConnected())
        { why = "No connection to trade server"; return(false); }
      if(MarketInfo(_Symbol, MODE_TRADEALLOWED) == 0.0)
        { why = "Trading not allowed on symbol"; return(false); }
     }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
     { why = "Invalid quotes"; return(false); }
   why = "";
   return(true);
  }

// effective distances; warns when inputs are below broker minimum
bool GetDist(double &d, double &sd, double &tr, double &tp)
  {
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = StopsDist();
   double spr  = (ask > bid) ? (ask - bid) : 0.0;
   double minDist = MathMax(minD, MinDistSpreadMult * spr);

   d  = DistancePips * g_pip;
   sd = SLPips * g_pip;
   tr = TrailPips * g_pip;
   tp = TPPips * g_pip;

   string w = "";
   if(d < minDist)
      w += StringFormat(" Distance %.1f<%.1f pip;", DistancePips, minDist / g_pip);
   if(sd < minD)
      w += StringFormat(" SL %.1f<%.1f pip;", SLPips, minD / g_pip);
   if(tr < minD)
      w += StringFormat(" Trail %.1f<%.1f pip;", TrailPips, minD / g_pip);
   if(tp > 0.0 && tp < minD)
      w += StringFormat(" TP %.1f<%.1f pip;", TPPips, minD / g_pip);

   if(w != "")
      Warn("input below broker minimum, raised automatically:" + w);

   d  = MathMax(d, minDist);
   sd = MathMax(sd, minD);
   tr = MathMax(tr, minD);
   if(tp > 0.0)
      tp = MathMax(tp, minD);
   return(true);
  }

string ParamWarn()
  {
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = StopsDist();
   double spr  = (ask > bid) ? (ask - bid) : 0.0;
   double minDist = MathMax(minD, MinDistSpreadMult * spr);
   string w = "";
   if(DistancePips * g_pip < minDist)
      w += "Dist<min ";
   if(SLPips * g_pip < minD)
      w += "SL<min ";
   if(TrailPips * g_pip < minD)
      w += "Trail<min ";
   if(Mode == SS_MODE_2 && !SpreadCompensation)
      w += "NoComp ";
   return(w);
  }

// pending expiry (server time); 0 = GTC
datetime GetExpiry()
  {
   if(PendingExpiryMin <= 0 || g_noExpiry)
      return(0);
   return((datetime)(TimeCurrent() + PendingExpiryMin * 60));
  }

//+------------------------------------------------------------------+
//| Order existence helpers (MT4: one pool for positions + pendings) |
//+------------------------------------------------------------------+
bool PosExists(const int ticket)
  {
   if(ticket <= 0)
      return(false);
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(false);
   return(OrderCloseTime() == 0 && (OrderType() == OP_BUY || OrderType() == OP_SELL));
  }

bool PendExists(const int ticket)
  {
   if(ticket <= 0)
      return(false);
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(false);
   return(OrderCloseTime() == 0 && OrderType() > OP_SELL);
  }

//+------------------------------------------------------------------+
//| Daily P/L tracking (display only, no trading limit)              |
//+------------------------------------------------------------------+
void UpdateRisk()
  {
   ulong now = NowMs();
   if(g_riskMs != 0 && now - g_riskMs < 1000)
      return;
   g_riskMs = now;

   long t = (long)TimeCurrent();
   datetime day0 = (datetime)(t - (t % 86400));
   g_day = day0;

   double realized = 0.0;
   int n = OrdersHistoryTotal();
   for(int i = 0; i < n; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderCloseTime() < day0)
         continue;
      if(OrderSymbol() != _Symbol)
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      int ty = OrderType();
      if(ty != OP_BUY && ty != OP_SELL)
         continue;
      realized += OrderProfit() + OrderSwap() + OrderCommission();
     }
   g_dayPL = realized + g_floating;
  }

//+------------------------------------------------------------------+
//| Scan positions and pending orders (symbol + magic)               |
//+------------------------------------------------------------------+
void Scan(SSnap &s)
  {
   s.nPos = 0;
   s.ptype = OP_BUY;
   s.pticket = 0;
   s.popen = 0.0;
   s.psl = 0.0;
   s.ptp = 0.0;
   s.pvol = 0.0;
   s.floating = 0.0;
   s.tBest = 0;
   s.nBuyStop = 0;
   s.nSellStop = 0;
   s.nOther = 0;
   s.tBuyStop = 0;
   s.tSellStop = 0;
   s.pBuyStop = 0.0;
   s.pSellStop = 0.0;
   s.expBuy = 0;
   s.expSell = 0;

   double bestP = -DBL_MAX;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != _Symbol)
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      int t  = OrderTicket();
      int ot = OrderType();
      if(ot == OP_BUY || ot == OP_SELL)
        {
         double pr = OrderProfit() + OrderSwap();
         s.floating += pr;
         s.nPos++;
         if(pr > bestP)
           {
            bestP = pr;
            s.tBest = t;
           }
         if(t > s.pticket)   // newest position
           {
            s.pticket = t;
            s.ptype = ot;
            s.popen = OrderOpenPrice();
            s.psl   = OrderStopLoss();
            s.ptp   = OrderTakeProfit();
            s.pvol  = OrderLots();
           }
        }
      else
         if(ot == OP_BUYSTOP)
           {
            s.nBuyStop++;
            s.tBuyStop = t;
            s.pBuyStop = OrderOpenPrice();
            s.expBuy   = OrderExpiration();
           }
         else
            if(ot == OP_SELLSTOP)
              {
               s.nSellStop++;
               s.tSellStop = t;
               s.pSellStop = OrderOpenPrice();
               s.expSell   = OrderExpiration();
              }
            else
               s.nOther++;
     }
  }

//+------------------------------------------------------------------+
//| Trade operations                                                 |
//+------------------------------------------------------------------+
bool DeleteOrder(const int ticket)
  {
   for(int a = 0; a < 3; a++)
     {
      if(!PendExists(ticket))
         return(true); // already gone (triggered or deleted)
      WaitCtx();
      ResetLastError();
      if(OrderDelete(ticket))
         return(true);
      g_lastErr = GetLastError();
      if(g_lastErr == SS_E_MODIFY_DENIED)
         break; // frozen: retrying immediately is pointless
     }
   return(!PendExists(ticket));
  }

// collect tickets of own pending orders (stop + limit)
int CollectPendings(int &arr[])
  {
   ArrayResize(arr, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != _Symbol)
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      if(OrderType() <= OP_SELL)
         continue;
      int n = ArraySize(arr);
      ArrayResize(arr, n + 1);
      arr[n] = OrderTicket();
     }
   return(ArraySize(arr));
  }

bool DeleteAllPendings()
  {
   ulong now = NowMs();
   if(now < g_delFailUntil)
      return(false);
   int tk[];
   int n = CollectPendings(tk);
   bool ok = true;
   for(int i = 0; i < n; i++)
      if(!DeleteOrder(tk[i]))
         ok = false;
   if(!ok)
     {
      g_delFailUntil = now + 1000;
      Warn(StringFormat("delete pending failed err=%d", g_lastErr));
     }
   return(ok);
  }

bool ClosePos(const int ticket)
  {
   int err = 0;
   int dev = (int)MathMax((double)Slippage, 0.0);
   for(int a = 0; a < 3; a++)
     {
      WaitCtx();
      if(!PosExists(ticket))
         return(true);
      double px = (OrderType() == OP_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ResetLastError();
      if(OrderClose(ticket, OrderLots(), px, dev, clrNONE))
        {
         g_failCount = 0;
         return(true);
        }
      err = GetLastError();
      if(err != SS_E_REQUOTE && err != SS_E_PRICE_CHANGED && err != SS_E_OFF_QUOTES)
         break;
     }
   if(!PosExists(ticket))
      return(true);
   OnFail("OrderClose", err);
   return(false);
  }

// close all own positions except 'keep' (keep = 0 -> close all)
void CloseAllExcept(const int keep)
  {
   int tk[];
   ArrayResize(tk, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != _Symbol)
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      if(OrderType() > OP_SELL)
         continue;
      int t = OrderTicket();
      if(t == keep)
         continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1);
      tk[n] = t;
     }
   for(int i = 0; i < ArraySize(tk); i++)
      if(!ClosePos(tk[i]))
         break; // failure -> cooldown, do not spam
  }

// two positions at once. Wait GraceMs (SL may close the old one), then
// Mode 2 keeps the NEWEST position (reversal chain survives), Mode 1 keeps the best.
void HandleExtras(const SSnap &s)
  {
   ulong now = NowMs();
   if(g_extraSince == 0)
     {
      g_extraSince = now;
      Print(StringFormat("ScalperStar: %d positions detected, waiting %d ms before cleanup", s.nPos, GraceMs));
     }
   if(now - g_extraSince < (ulong)MathMax((double)GraceMs, 0.0))
      return;
   if(Cooling())
      return;
   int keep = (Mode == SS_MODE_2) ? s.pticket : s.tBest;
   CloseAllExcept(keep);
   if(s.nBuyStop + s.nSellStop + s.nOther > 0)
      DeleteAllPendings();
  }

bool PlaceStop(const int type, const double price, const double sl, const double tp, const double lot)
  {
   datetime ex = GetExpiry();
   int dev = (int)MathMax((double)Slippage, 0.0);
   int err = 0;
   for(int a = 0; a < 2; a++)
     {
      WaitCtx();
      ResetLastError();
      int tk = OrderSend(_Symbol, type, lot, price, dev, sl, tp, "ScalperStar", MagicNumber, ex, clrNONE);
      if(tk > 0)
        {
         g_failCount = 0;
         return(true);
        }
      err = GetLastError();
      if(err == SS_E_EXPIRY_DENIED && ex != 0)
        {
         g_noExpiry = true;   // broker does not accept expiration -> GTC from now on
         Warn("broker denies pending expiration - switching to GTC pendings");
         ex = 0;
         continue;
        }
      break;
     }
   OnFail(type == OP_BUYSTOP ? "BuyStop" : "SellStop", err);
   return(false);
  }

bool SendMarket(const bool buy, const double lot, const double sl, const double tp)
  {
   int  dev     = (int)MathMax((double)Slippage, 0.0);
   int  err     = 0;
   bool noStops = false;
   for(int a = 0; a < 3; a++)
     {
      WaitCtx();
      double px = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ResetLastError();
      int tk = OrderSend(_Symbol, buy ? OP_BUY : OP_SELL, lot, px, dev,
                         noStops ? 0.0 : sl, noStops ? 0.0 : tp, "ScalperStar", MagicNumber, 0, clrNONE);
      if(tk > 0)
        {
         g_failCount = 0;
         return(true);   // if sent without SL/TP, FixInitialSL() sets them on the next pass
        }
      err = GetLastError();
      if(err == SS_E_REQUOTE || err == SS_E_PRICE_CHANGED || err == SS_E_OFF_QUOTES)
         continue;
      if(err == SS_E_INVALID_STOPS && !noStops && sl > 0.0)
        {
         noStops = true;   // some brokers refuse SL/TP on market orders: send naked, set SL right after
         Warn("market order with SL/TP rejected - sending without, SL set right after");
         continue;
        }
      break;
     }
   OnFail(buy ? "Buy(market)" : "Sell(market)", err);
   return(false);
  }

bool ModifySL(const int ticket, const double sl, const double tp)
  {
   g_reqSent = true;
   WaitCtx();
   if(!PosExists(ticket))
      return(false);
   ResetLastError();
   if(OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), 0, clrNONE))
      return(true);
   int err = GetLastError();
   if(err == SS_E_NO_RESULT || err == 0)
      return(true);   // nothing changed
   ModFail(err);
   return(false);
  }

//--- start a new cycle: Buy Stop + Sell Stop
bool StartCycle()
  {
   if(!SpreadOK())
      return(false);
   string why;
   if(!CanTradeNow(why))
     {
      Warn(why);
      Cool(5000);
      return(false);
     }
   double d, sd, tr, tp;
   if(!GetDist(d, sd, tr, tp))
     {
      Cool(5000);
      return(false);
     }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lot = FitLot(CalcLot(), 2);
   if(lot <= 0.0)
     {
      Warn("margin/volume not sufficient - cycle skipped");
      Cool(5000);
      return(false);
     }
   g_cycleLot = lot;

   double bp  = NormalizeDouble(ask + d, _Digits);
   double sp  = NormalizeDouble(bid - d, _Digits);
   double bsl = NormalizeDouble(bp - sd, _Digits);
   double ssl = NormalizeDouble(sp + sd, _Digits);
   double btp = (tp > 0.0) ? NormalizeDouble(bp + tp, _Digits) : 0.0;
   double stp = (tp > 0.0) ? NormalizeDouble(sp - tp, _Digits) : 0.0;

   if(!PlaceStop(OP_BUYSTOP, bp, bsl, btp, lot))
      return(false);
   if(!PlaceStop(OP_SELLSTOP, sp, ssl, stp, lot))
     {
      g_delFailUntil = 0;
      DeleteAllPendings(); // never leave a lone side; cooldown already set
      return(false);
     }
   return(true);
  }

// SL/TP measured from the real fill price, not from the pending price
void FixInitialSL(const SSnap &s)
  {
   if(s.nPos != 1 || s.pticket == 0)
      return;
   if(s.pticket == g_slChecked && s.psl > 0.0)
      return;
   if(NowMs() < g_modFailUntil)
      return;
   double minD = StopsDist();
   double d, sd, tr, tp;
   if(!GetDist(d, sd, tr, tp))
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isBuy = (s.ptype == OP_BUY);

   double wantSL, wantTP = s.ptp;
   if(isBuy)
     {
      wantSL = NormalizeDouble(s.popen - sd, _Digits);
      double lim = NormalizeDouble(bid - minD, _Digits);
      if(wantSL > lim)
         wantSL = lim;
      if(tp > 0.0)
         wantTP = NormalizeDouble(s.popen + tp, _Digits);
     }
   else
     {
      wantSL = NormalizeDouble(s.popen + sd, _Digits);
      double lim = NormalizeDouble(ask + minD, _Digits);
      if(wantSL < lim)
         wantSL = lim;
      if(tp > 0.0)
         wantTP = NormalizeDouble(s.popen - tp, _Digits);
     }
   // only tighten (never loosen a trailed SL)
   bool needSL = (s.psl <= 0.0) ||
                 (isBuy ? (s.psl < wantSL - _Point * 1.5) : (s.psl > wantSL + _Point * 1.5));
   bool needTP = (tp > 0.0) && (s.ptp <= 0.0 || MathAbs(s.ptp - wantTP) > _Point * 1.5);
   if(!needSL && !needTP)
     {
      g_slChecked = s.pticket;
      return;
     }
   if(ModifySL(s.pticket, needSL ? wantSL : s.psl, needTP ? wantTP : s.ptp))
      g_slChecked = s.pticket;
  }

//--- one-direction trailing of the open position
// profitFirst = true (Mode 1): trailing starts only when the position is in
// profit by at least the trail distance (Bid for Buy, Ask for Sell). At that
// moment bid - trail == open price, so the SL lands exactly on break-even and
// then follows the price. Before that the initial SL stays untouched.
void ManageTrail(const SSnap &s, const bool profitFirst = false)
  {
   double d, sd, trail, tp;
   if(!GetDist(d, sd, trail, tp))
      return;
   double frz  = FreezeDist();
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double step = MathMax((double)TrailStepPoints, 1.0) * _Point;

   if(s.ptype == OP_BUY)
     {
      if(profitFirst && (bid - s.popen) < trail - _Point * 0.5)
         return;
      if(frz > 0.0 && s.psl > 0.0 && (bid - s.psl) <= frz)
         return;
      double nsl = NormalizeDouble(bid - trail, _Digits);
      if(nsl >= bid)
         return;
      if(s.psl > 0.0 && (nsl - s.psl) < step)
         return;
      ModifySL(s.pticket, nsl, s.ptp);
     }
   else
     {
      if(profitFirst && (s.popen - ask) < trail - _Point * 0.5)
         return;
      if(frz > 0.0 && s.psl > 0.0 && (s.psl - ask) <= frz)
         return;
      double nsl = NormalizeDouble(ask + trail, _Digits);
      if(nsl <= ask)
         return;
      if(s.psl > 0.0 && (s.psl - nsl) < step)
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
      HandleExtras(s);
      return;
     }
   if(s.nPos == 1)
     {
      // fast delete of opposite pending
      if(s.nBuyStop + s.nSellStop + s.nOther > 0)
         DeleteAllPendings();
      g_reqSent = false;
      FixInitialSL(s);
      if(!g_reqSent && ModDue())
         ManageTrail(s, true); // trail only after profit >= TrailPips
      if(g_reqSent)
         g_lastModMs = NowMs();
      return;
     }
   // no position
   int np = s.nBuyStop + s.nSellStop + s.nOther;
   if(s.nBuyStop == 1 && s.nSellStop == 1 && s.nOther == 0)
      return; // PENDING
   if(np > 0)
     {
      DeleteAllPendings(); // abnormal -> restart
      return;
     }
   if(Cooling())
      return;
   StartCycle();
  }

//+------------------------------------------------------------------+
//| MODE 2                                                           |
//+------------------------------------------------------------------+
// 1 = last chain position closed by SL, 0 = closed by something else,
// -1 = history not updated yet
int LastCloseResult()
  {
   if(g_lastTicket <= 0)
      return(-1);
   if(!OrderSelect(g_lastTicket, SELECT_BY_TICKET))
      return(-1);
   if(OrderCloseTime() == 0)
      return(-1);   // still open / history not yet updated
   string cm = OrderComment();
   if(StringFind(cm, "[tp]") >= 0)
      return(0);
   if(StringFind(cm, "[sl]") >= 0)
      return(1);
   // no broker tag: compare close price with the SL price
   double sl = OrderStopLoss();
   double cp = OrderClosePrice();
   double tol = MathMax((double)Slippage, 2.0) * _Point;
   if(sl > 0.0 && MathAbs(cp - sl) <= tol)
      return(1);
   return(0);
  }

void ResetChain()
  {
   g_chain      = false;
   g_revCount   = 0;
   g_curTicket  = 0;
   g_lastTicket = 0;
   g_waitSince  = 0;
  }

// keep the opposite pending glued to the position SL
void SyncOpposite(const SSnap &s, const bool allowMod)
  {
   bool isBuy = (s.ptype == OP_BUY);
   int  nOpp  = isBuy ? s.nSellStop : s.nBuyStop;
   int  nBad  = isBuy ? (s.nBuyStop + s.nOther) : (s.nSellStop + s.nOther);

   if(nBad > 0 || nOpp > 1)
     {
      DeleteAllPendings(); // abnormal -> clean, re-place next tick
      return;
     }
   if(s.psl <= 0.0)
      return;

   double d, sd, tr, tpd;
   if(!GetDist(d, sd, tr, tpd))
      return;
   double minD = StopsDist();
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Position SL and the opposite stop share the same price basis
   // (Buy SL & Sell Stop -> Bid, Sell SL & Buy Stop -> Ask) => exact SL price.
   // Price is ALWAYS clamped to a valid distance, otherwise the order is rejected.
   double P = NormalizeDouble(s.psl, _Digits);
   bool clamped = false;
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

   if(nOpp == 0)
     {
      if(Cooling())
         return;
      string why;
      if(!CanTradeNow(why))
        {
         Warn(why);
         Cool(5000);
         return;
        }
      double want = ReverseLotRecalc ? CalcLot() : s.pvol;
      double lot  = FitLot(want, 1);
      if(lot <= 0.0)
        {
         Warn("margin/volume not sufficient - reversal order skipped");
         Cool(5000);
         return;
        }
      g_chainLot = lot;
      double pSL = isBuy ? NormalizeDouble(P + sd, _Digits) : NormalizeDouble(P - sd, _Digits);
      double pTP = 0.0;
      if(tpd > 0.0)
         pTP = isBuy ? NormalizeDouble(P - tpd, _Digits) : NormalizeDouble(P + tpd, _Digits);
      PlaceStop(isBuy ? OP_SELLSTOP : OP_BUYSTOP, P, pSL, pTP, lot);
      return;
     }

   int      tk   = isBuy ? s.tSellStop : s.tBuyStop;
   double   cur  = isBuy ? s.pSellStop : s.pBuyStop;
   datetime cexp = isBuy ? s.expSell : s.expBuy;

   // expiry refresh before the pending times out
   datetime ex = GetExpiry();
   bool refresh = (ex > 0 && cexp > 0 &&
                   (long)(cexp - TimeCurrent()) < (long)(PendingExpiryMin * 60) / 3);

   bool skip = false;
   if(MathAbs(cur - s.psl) < _Point * 0.9)
      skip = true; // already exactly at SL
   else
      if(clamped && isBuy && P <= cur + _Point * 0.9)
         skip = true;
      else
         if(clamped && !isBuy && P >= cur - _Point * 0.9)
            skip = true;
         else
            if(MathAbs(cur - P) < _Point * 0.9)
               skip = true;
   if(skip && !refresh)
      return;
   if(!allowMod)
      return;
   if(NowMs() < g_modFailUntil)
      return;

   // pending too close to market = frozen
   double frz = FreezeDist();
   if(frz > 0.0)
     {
      if(isBuy && (bid - cur) <= frz)
         return;
      if(!isBuy && (cur - ask) <= frz)
         return;
     }

   double newP   = skip ? cur : P;
   double pendSL = isBuy ? NormalizeDouble(newP + sd, _Digits) : NormalizeDouble(newP - sd, _Digits);
   double pendTP = 0.0;
   if(tpd > 0.0)
      pendTP = isBuy ? NormalizeDouble(newP - tpd, _Digits) : NormalizeDouble(newP + tpd, _Digits);

   g_reqSent = true;
   WaitCtx();
   ResetLastError();
   if(!OrderModify(tk, NormalizeDouble(newP, _Digits), pendSL, pendTP, ex, clrNONE))
     {
      int err = GetLastError();
      if(err == SS_E_EXPIRY_DENIED)
        {
         g_noExpiry = true;
         Warn("broker denies pending expiration - switching to GTC pendings");
        }
      if(err != SS_E_NO_RESULT && err != 0)
         ModFail(err);
     }
  }

// SL was hit but the opposite pending did not trigger: open reverse at market
void ReverseByMarket(const SSnap &s)
  {
   bool wasBuy = (g_lastType == OP_BUY);
   if((wasBuy && s.nSellStop != 1) || (!wasBuy && s.nBuyStop != 1))
     {
      DeleteAllPendings();
      ResetChain();
      return;
     }
   if(Cooling())
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // pending is about to trigger by itself -> wait
   if(wasBuy && bid <= s.pSellStop + _Point * 0.5)
      return;
   if(!wasBuy && ask >= s.pBuyStop - _Point * 0.5)
      return;

   string why;
   if(!CanTradeNow(why))
     {
      Warn(why);
      Cool(5000);
      return;
     }
   double want = ReverseLotRecalc ? CalcLot() : g_chainLot;
   double lot  = FitLot(want, 1);
   if(lot <= 0.0)
     {
      Warn("margin/volume not sufficient - market reversal skipped");
      Cool(5000);
      return;
     }

   int tk = wasBuy ? s.tSellStop : s.tBuyStop;
   if(!DeleteOrder(tk))
      return;

   SSnap t;
   Scan(t);
   if(t.nPos > 0)
      return; // pending triggered in the meantime

   double d, sd, tr, tpd;
   if(!GetDist(d, sd, tr, tpd))
      return;
   double minD = StopsDist();
   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(wasBuy)
     {
      double sl = NormalizeDouble(MathMax(bid + sd, ask + minD), _Digits);
      double tp = (tpd > 0.0) ? NormalizeDouble(bid - tpd, _Digits) : 0.0;
      SendMarket(false, lot, sl, tp);
     }
   else
     {
      double sl = NormalizeDouble(MathMin(ask - sd, bid - minD), _Digits);
      double tp = (tpd > 0.0) ? NormalizeDouble(ask + tpd, _Digits) : 0.0;
      SendMarket(true, lot, sl, tp);
     }
  }

void RunMode2(const SSnap &s)
  {
   ulong now = NowMs();
   if(s.nPos > 1)
     {
      HandleExtras(s);
      return;
     }
   if(s.nPos == 1)
     {
      if(s.pticket != g_curTicket || s.ptype != g_curType)
        {
         if(g_chain)
            g_revCount++;
         g_curTicket = s.pticket;
         g_curType   = s.ptype;
        }
      g_chain      = true;
      g_lastType   = s.ptype;
      g_lastTicket = s.pticket;
      g_chainLot   = s.pvol;
      g_waitSince  = 0;

      bool doMod = ModDue();
      g_reqSent = false;
      FixInitialSL(s);
      SSnap t = s;
      if(!g_reqSent && doMod)
         ManageTrail(s);
      if(g_reqSent)
         Scan(t); // position SL changed -> re-read before syncing the pending
      SyncOpposite(t, doMod || g_reqSent);
      if(g_reqSent)
         g_lastModMs = now;
      return;
     }

   // no position
   int np = s.nBuyStop + s.nSellStop + s.nOther;
   if(np == 0)
     {
      ResetChain();
      if(Cooling())
         return;
      StartCycle();
      return;
     }
   if(s.nBuyStop == 1 && s.nSellStop == 1 && s.nOther == 0)
     {
      ResetChain(); // fresh cycle waiting
      return;
     }
   if(g_chain && np == 1 && s.nOther == 0)
     {
      int r = LastCloseResult();
      if(r == -1)
        {
         // history not updated yet: retry for HistoryWaitMs before giving up
         if(g_waitSince == 0)
            g_waitSince = now;
         if(now - g_waitSince < (ulong)MathMax((double)HistoryWaitMs, 0.0))
            return;
         Warn("order history not available - chain reset (set Account History to 'All History')");
        }
      else
         if(r == 1)
           {
            if(SpreadCompensation)
              {
               ReverseByMarket(s);
               return;
              }
            // no compensation: give the pending a short chance to trigger by itself
            if(g_waitSince == 0)
               g_waitSince = now;
            if(now - g_waitSince < (ulong)MathMax((double)GraceMs, 0.0))
               return;
           }
     }
   // abnormal -> clean and restart
   DeleteAllPendings();
   ResetChain();
  }

//+------------------------------------------------------------------+
//| Main logic                                                       |
//+------------------------------------------------------------------+
void DoLogic()
  {
   SSnap s;
   Scan(s);
   g_floating = s.floating;
   if(g_panelOn)
      UpdateRisk();
   if(s.nPos <= 1)
      g_extraSince = 0;

   if(Mode == SS_MODE_1)
      RunMode1(s);
   else
      RunMode2(s);
  }

void RunLogic()
  {
   if(g_inLogic)
      return;
   g_inLogic = true;
   DoLogic();
   g_inLogic = false;
  }

//+------------------------------------------------------------------+
//| Panel (updated at most once per second)                          |
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
   int x = 10, y = 22, w = 270, h = 250;
   MakeRect("bg", x, y, w, h, C'10,15,40', clrDeepSkyBlue);
   MakeRect("hd", x, y, w, 26, C'255,140,0', C'255,140,0');
   MakeLbl("title", x + 10, y + 4, "ScalperStar", clrWhite, 12, "Arial Black");
   string names[10] = {"Mode", "Spread", "Status", "Lot", "Lot Mode", "Equity", "Balance",
                       "Floating P/L", "Daily P/L", "Info"};
   for(int i = 0; i < 10; i++)
     {
      int yy = y + 36 + i * 20;
      MakeLbl("k" + IntegerToString(i), x + 10, yy, names[i] + ":", clrSilver, 9, "Arial");
      MakeLbl("v" + IntegerToString(i), x + 100, yy, "-", clrWhite, 9, "Arial");
     }
  }

void UpdatePanel()
  {
   if(!g_panelOn)
      return;
   ulong now = NowMs();
   if(g_panelMs != 0 && now - g_panelMs < 1000)
      return;
   g_panelMs = now;

   SSnap s;
   Scan(s);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    spPts  = (int)MathRound((ask - bid) / _Point);
   double spPips = (g_pip > 0.0) ? (ask - bid) / g_pip : 0.0;

   color sc = clrLime;
   if(spPips <= 1.5)
      sc = clrLime;
   else
      if(spPips <= 3.0)
         sc = clrYellow;
      else
         sc = clrRed;

   string stTxt = "IDLE";
   color  stClr = clrSilver;
   double lot   = 0.0;
   int    np    = s.nBuyStop + s.nSellStop + s.nOther;

   if(s.nPos >= 1)
     {
      lot = s.pvol;
      if(s.ptype == OP_BUY)
        {
         g_state = SS_IN_BUY;
         stTxt = "BUY";
         stClr = clrLime;
        }
      else
        {
         g_state = SS_IN_SELL;
         stTxt = "SELL";
         stClr = clrTomato;
        }
     }
   else
      if(np > 0)
        {
         g_state = SS_PENDING;
         stTxt = "PENDING";
         stClr = clrYellow;
         lot = (g_cycleLot > 0.0) ? g_cycleLot : CalcLot();
        }
      else
        {
         g_state = SS_IDLE;
         lot = CalcLot();
        }

   color fc = clrWhite;
   if(s.floating > 0.0)
      fc = clrLime;
   else
      if(s.floating < 0.0)
         fc = clrRed;
   color dc = clrWhite;
   if(g_dayPL > 0.0)
      dc = clrLime;
   else
      if(g_dayPL < 0.0)
         dc = clrRed;

   string info = "OK";
   color  ic   = clrLime;
   string pw   = ParamWarn();
   if(Cooling())
     {
      info = "Cooldown (request failed)";
      ic = clrOrange;
     }
   else
      if(pw != "")
        {
         info = pw;
         ic = clrYellow;
        }

   string cur = AccountCurrency();

   SetVal(0, (Mode == SS_MODE_1) ? "Mode 1" : "Mode 2", clrAqua);
   SetVal(1, IntegerToString(spPts) + " pt / " + DoubleToString(spPips, 1) + " pip", sc);
   SetVal(2, stTxt, stClr);
   SetVal(3, DoubleToString(lot, 2), clrWhite);
   SetVal(4, (LotMode == SS_FIXED_LOT) ? "FIXED_LOT" : "EQUITY_LOT", clrOrange);
   SetVal(5, DoubleToString(AccountEquity(), 2) + " " + cur, clrWhite);
   SetVal(6, DoubleToString(AccountBalance(), 2) + " " + cur, clrWhite);
   SetVal(7, DoubleToString(s.floating, 2) + " " + cur, fc);
   SetVal(8, DoubleToString(g_dayPL, 2) + " " + cur, dc);
   SetVal(9, info, ic);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_tester = (bool)MQLInfoInteger(MQL_TESTER);

   if(DistancePips <= 0.0 || SLPips <= 0.0 || TrailPips <= 0.0 || FixedLot <= 0.0 ||
      TPPips < 0.0 || PointsPerPip < 0 ||
      MinDistSpreadMult < 0.0 || MagicNumber < 0)
     {
      Print("ScalperStar: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(PointsPerPip > 0)
      g_pip = (double)PointsPerPip * _Point;
   else
      g_pip = (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;

   Print(StringFormat("ScalperStar: %s digits=%d point=%s pip=%s stopsLevel=%d freezeLevel=%d minDist=%.1f pip",
                      _Symbol, _Digits, DoubleToString(_Point, _Digits), DoubleToString(g_pip, _Digits),
                      (int)MarketInfo(_Symbol, MODE_STOPLEVEL),
                      (int)MarketInfo(_Symbol, MODE_FREEZELEVEL),
                      StopsDist() / g_pip));
   double d, sd, tr, tp;
   GetDist(d, sd, tr, tp);
   if(Mode == SS_MODE_2 && !SpreadCompensation)
      Warn("Mode 2 with SpreadCompensation=false: no market-order gap closing, a reversal can be missed");
   if(PendingExpiryMin <= 0)
      Warn("PendingExpiryMin=0: pending orders are GTC and can survive the weekend");

   g_panelOn = !(g_tester && !(bool)MQLInfoInteger(MQL_VISUAL_MODE));
   if(g_panelOn)
      CreatePanel();
   if(!g_tester)
     {
      int ms = (int)MathMax((double)TimerMs, 50.0);
      if(!EventSetMillisecondTimer(ms))
         EventSetTimer(1);
     }
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

// MT4 has no OnTradeTransaction: a fast timer reacts to fills instead
void OnTimer()
  {
   RunLogic();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
