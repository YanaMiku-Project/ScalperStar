//+------------------------------------------------------------------+
//|                                                  ScalperStar.mq5 |
//|                  Stop-order scalper: Mode 1 / Mode 2 (v2.00)     |
//|   v3.60: all pause / stop filters removed (always-on trading)    |
//+------------------------------------------------------------------+
#property copyright "ScalperStar"
#property version   "3.60"
#property description "ScalperStar - Buy Stop / Sell Stop scalper with trailing (Mode 1 & Mode 2 reversal), hardened"

#include <Trade\Trade.mqh>

const string PFX = "ScalperStar_";

//--- enums (prefixed to avoid name clashes - #17)
enum ENUM_SS_MODE    { SS_MODE_1 = 1,       // Mode 1 (OCO breakout)
                       SS_MODE_2 = 2 };     // Mode 2 (reversal chain)
enum ENUM_SS_LOTMODE { SS_FIXED_LOT = 0,    // Fixed lot
                       SS_EQUITY_LOT = 1 }; // Equity based lot
enum ENUM_SS_STATE   { SS_IDLE = 0, SS_PENDING = 1, SS_IN_BUY = 2, SS_IN_SELL = 3 };
enum ENUM_SS_FILL    { SS_FILL_AUTO = 0,    // Auto (with fallback)
                       SS_FILL_FOK = 1,     // FOK first
                       SS_FILL_IOC = 2,     // IOC first
                       SS_FILL_RETURN = 3 };// Return first

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
input long            MagicNumber        = 20260101;      // Magic Number

input group "=== Eksekusi aman ==="
input ENUM_SS_FILL    FillingMode        = SS_FILL_AUTO;  // Prioritas filling mode
input int             StopsBufferPoints  = 3;             // Buffer di atas stops/freeze level (point)
input double          MinDistSpreadMult  = 3.0;           // Jarak pending minimum = N x spread
input int             CooldownMs         = 2000;          // Cooldown dasar setelah request gagal (ms)
input int             ModifyIntervalMs   = 300;           // Jeda minimum antar modify trailing/pending (ms)
input int             TrailStepPoints    = 5;             // Langkah minimum trailing (point)
input int             GraceMs            = 1500;          // Tahan cleanup saat 2 posisi muncul (ms)
input int             HistoryWaitMs      = 3000;          // Tunggu history deal terupdate (ms)
input int             PendingExpiryMin   = 60;            // Expiry pending (menit), 0 = GTC

//--- snapshot of own positions / pending orders
struct SSnap
  {
   int               nPos;
   ENUM_POSITION_TYPE ptype;
   ulong             pticket;     // NEWEST position ticket
   long              pid;         // position identifier
   double            popen;
   double            psl;
   double            ptp;
   double            pvol;
   double            floating;
   ulong             tBest;       // position with best floating P/L
   int               nBuyStop;
   int               nSellStop;
   int               nOther;
   ulong             tBuyStop;
   ulong             tSellStop;
   double            pBuyStop;
   double            pSellStop;
   datetime          expBuy;
   datetime          expSell;
  };

//--- globals
CTrade             trade;
bool               g_tester     = false;
bool               g_panelOn    = true;
double             g_pip        = 0.0;
ENUM_SS_STATE      g_state      = SS_IDLE;
double             g_cycleLot   = 0.0;

// chain (Mode 2)
bool               g_chain      = false;
ENUM_POSITION_TYPE g_lastType   = POSITION_TYPE_BUY;
ulong              g_curTicket  = 0;
ENUM_POSITION_TYPE g_curType    = POSITION_TYPE_BUY;
long               g_lastPosId  = 0;
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
ulong              g_slChecked    = 0;

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
     {
      long t = SymbolInfoInteger(_Symbol, SYMBOL_TIME_MSC);
      if(t > 0)
         return((ulong)t);
      return((ulong)TimeCurrent() * 1000);
     }
   return(GetTickCount64());
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
bool RetOK(const uint rc)
  {
   return(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED ||
          rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_NO_CHANGES);
  }

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

// failure of an order/close request -> cooldown with back-off (#3)
void OnFail(const string ctx)
  {
   uint rc = trade.ResultRetcode();
   g_failCount++;
   ulong cd = (ulong)MathMax(CooldownMs, 200) * (ulong)MathMin(g_failCount, 5);
   if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_TRADE_DISABLED ||
      rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_CLIENT_DISABLES_AT ||
      rc == TRADE_RETCODE_SERVER_DISABLES_AT || rc == TRADE_RETCODE_LONG_ONLY ||
      rc == TRADE_RETCODE_SHORT_ONLY || rc == TRADE_RETCODE_LIMIT_ORDERS ||
      rc == TRADE_RETCODE_LIMIT_VOLUME)
     {
      if(cd < 30000)
         cd = 30000;
     }
   else
      if(rc == TRADE_RETCODE_TOO_MANY_REQUESTS && cd < 5000)
         cd = 5000;
   Cool(cd);
   Print(StringFormat("ScalperStar: %s failed rc=%u (%s), cooldown %I64u ms",
                      ctx, rc, trade.ResultRetcodeDescription(), cd));
  }

void ModFail()
  {
   uint rc = trade.ResultRetcode();
   ulong cd = (rc == TRADE_RETCODE_FROZEN || rc == TRADE_RETCODE_TOO_MANY_REQUESTS) ? 3000 : 1000;
   g_modFailUntil = NowMs() + cd;
   Warn(StringFormat("modify failed rc=%u (%s)", rc, trade.ResultRetcodeDescription()));
  }

bool ModDue()
  {
   ulong now = NowMs();
   if(now < g_modFailUntil)
      return(false);
   return(now - g_lastModMs >= (ulong)MathMax(ModifyIntervalMs, 0));
  }

// minimum distance: max(stops, freeze) + buffer (#5)
double StopsDist()
  {
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fr = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long mx = MathMax(sl, fr);
   return((double)(mx + MathMax(StopsBufferPoints, 1)) * _Point);
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
   if(LotMode == SS_EQUITY_LOT && EquityPerLot > 0.0)
     {
      double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
      double mult = MathFloor(eq / EquityPerLot - 1.0);
      if(mult > 0.0)
         lot = FixedLot + mult * LotStep;
     }
   return(NormLot(lot));
  }

// lot reduced to what margin allows; 0 = cannot trade (#4)
// sides: how many such positions could be open at the same time
double FitLot(const double lotWanted, const int sides)
  {
   double want = NormLot(lotWanted);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m    = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, want, ask, m))
      return(0.0);
   if(m <= 0.0)
      return(want);
   double mpl  = m / want;
   double room = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(room <= 0.0)
      return(0.0);
   double maxLot = room / (mpl * (double)MathMax(sides, 1));
   double lot    = MathMin(want, maxLot);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
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

// trading permissions (#4)
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
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     { why = "Symbol trade mode is not FULL"; return(false); }
   long om = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if((om & SYMBOL_ORDER_STOP) == 0)
     { why = "Stop orders not allowed on symbol"; return(false); }
   if((om & SYMBOL_ORDER_SL) == 0)
     { why = "Stop Loss not allowed on symbol"; return(false); }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
     { why = "Invalid quotes"; return(false); }
   why = "";
   return(true);
  }

// effective distances; warns when inputs are below broker minimum (#6)
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
     {
      Warn("input below broker minimum, raised automatically:" + w);
     }
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

// pending expiry (#10)
void GetExpiry(ENUM_ORDER_TYPE_TIME &tt, datetime &ex)
  {
   tt = ORDER_TIME_GTC;
   ex = 0;
   if(PendingExpiryMin <= 0)
      return;
   long em = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((em & SYMBOL_EXPIRATION_SPECIFIED) != 0)
     {
      tt = ORDER_TIME_SPECIFIED;
      ex = TimeTradeServer() + PendingExpiryMin * 60;
     }
   else
      if((em & SYMBOL_EXPIRATION_DAY) != 0)
         tt = ORDER_TIME_DAY;
  }

// filling candidates with fallback (#9)
void AddFill(ENUM_ORDER_TYPE_FILLING &f[], const ENUM_ORDER_TYPE_FILLING v)
  {
   int n = ArraySize(f);
   for(int i = 0; i < n; i++)
      if(f[i] == v)
         return;
   ArrayResize(f, n + 1);
   f[n] = v;
  }

int BuildFill(const bool pending, ENUM_ORDER_TYPE_FILLING &f[])
  {
   ArrayResize(f, 0);
   long fm  = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   bool fok = ((fm & SYMBOL_FILLING_FOK) != 0);
   bool ioc = ((fm & SYMBOL_FILLING_IOC) != 0);
   if(FillingMode == SS_FILL_FOK)
      AddFill(f, ORDER_FILLING_FOK);
   else
      if(FillingMode == SS_FILL_IOC)
         AddFill(f, ORDER_FILLING_IOC);
      else
         if(FillingMode == SS_FILL_RETURN)
            AddFill(f, ORDER_FILLING_RETURN);
   if(pending)
     {
      AddFill(f, ORDER_FILLING_RETURN);
      if(ioc)
         AddFill(f, ORDER_FILLING_IOC);
      if(fok)
         AddFill(f, ORDER_FILLING_FOK);
     }
   else
     {
      if(ioc)
         AddFill(f, ORDER_FILLING_IOC);
      if(fok)
         AddFill(f, ORDER_FILLING_FOK);
      AddFill(f, ORDER_FILLING_RETURN);
     }
   return(ArraySize(f));
  }

//+------------------------------------------------------------------+
//| Daily P/L tracking (display only, no trading limit)              |
//+------------------------------------------------------------------+
// daily P/L (realized by this symbol+magic + floating), informational only
void UpdateRisk()
  {
   ulong now = NowMs();
   if(g_riskMs != 0 && now - g_riskMs < 1000)
      return;
   g_riskMs = now;

   datetime t = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day0 = StructToTime(dt);
   if(day0 != g_day)
      g_day = day0;

   double realized = 0.0;
   if(HistorySelect(day0, t + 60))
     {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong dl = HistoryDealGetTicket(i);
         if(dl == 0)
            continue;
         if(HistoryDealGetString(dl, DEAL_SYMBOL) != _Symbol)
            continue;
         if((long)HistoryDealGetInteger(dl, DEAL_MAGIC) != MagicNumber)
            continue;
         long dtp = HistoryDealGetInteger(dl, DEAL_TYPE);
         if(dtp != DEAL_TYPE_BUY && dtp != DEAL_TYPE_SELL)
            continue;
         realized += HistoryDealGetDouble(dl, DEAL_PROFIT) + HistoryDealGetDouble(dl, DEAL_SWAP) +
                     HistoryDealGetDouble(dl, DEAL_COMMISSION) + HistoryDealGetDouble(dl, DEAL_FEE);
        }
     }
   g_dayPL = realized + g_floating;
  }

//+------------------------------------------------------------------+
//| Scan positions and pending orders (symbol + magic)               |
//+------------------------------------------------------------------+
void Scan(SSnap &s)
  {
   s.nPos = 0;
   s.ptype = POSITION_TYPE_BUY;
   s.pticket = 0;
   s.pid = 0;
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
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      double pr = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
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
         s.ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         s.pid   = PositionGetInteger(POSITION_IDENTIFIER);
         s.popen = PositionGetDouble(POSITION_PRICE_OPEN);
         s.psl   = PositionGetDouble(POSITION_SL);
         s.ptp   = PositionGetDouble(POSITION_TP);
         s.pvol  = PositionGetDouble(POSITION_VOLUME);
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
         s.expBuy   = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
        }
      else
         if(ot == ORDER_TYPE_SELL_STOP)
           {
            s.nSellStop++;
            s.tSellStop = t;
            s.pSellStop = OrderGetDouble(ORDER_PRICE_OPEN);
            s.expSell   = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
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
      if(!OrderSelect(ticket))
         return(true); // already gone (triggered or deleted)
      if(trade.OrderDelete(ticket) && RetOK(trade.ResultRetcode()))
         return(true);
     }
   return(!OrderSelect(ticket));
  }

bool DeleteAllPendings()
  {
   ulong now = NowMs();
   if(now < g_delFailUntil)
      return(false);
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
   if(!ok)
     {
      g_delFailUntil = now + 1000;
      Warn(StringFormat("delete pending failed rc=%u (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
     }
   return(ok);
  }

bool ClosePos(const ulong ticket)
  {
   ENUM_ORDER_TYPE_FILLING f[];
   int n = BuildFill(false, f);
   for(int i = 0; i < n; i++)
     {
      if(!PositionSelectByTicket(ticket))
         return(true);
      trade.SetTypeFilling(f[i]);
      if(trade.PositionClose(ticket) && RetOK(trade.ResultRetcode()))
         return(true);
      if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_FILL)
         break;
     }
   if(!PositionSelectByTicket(ticket))
      return(true);
   OnFail("PositionClose");
   return(false);
  }

// close all own positions except 'keep' (keep = 0 -> close all)
void CloseAllExcept(const ulong keep)
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
      if(t == keep)
         continue;
      if(!ClosePos(t))
         break; // failure -> cooldown, do not spam
     }
  }

// #1: two positions at once. Wait GraceMs (SL may close the old one), then
// Mode 2 keeps the NEWEST position (reversal chain survives), Mode 1 keeps the best.
void HandleExtras(const SSnap &s)
  {
   ulong now = NowMs();
   if(g_extraSince == 0)
     {
      g_extraSince = now;
      Print(StringFormat("ScalperStar: %d positions detected, waiting %d ms before cleanup", s.nPos, GraceMs));
     }
   if(now - g_extraSince < (ulong)MathMax(GraceMs, 0))
      return;
   if(Cooling())
      return;
   ulong keep = (Mode == SS_MODE_2) ? s.pticket : s.tBest;
   CloseAllExcept(keep);
   if(s.nBuyStop + s.nSellStop + s.nOther > 0)
      DeleteAllPendings();
  }

bool PlaceStop(const ENUM_ORDER_TYPE type, const double price, const double sl, const double tp, const double lot)
  {
   ENUM_ORDER_TYPE_FILLING f[];
   int n = BuildFill(true, f);
   ENUM_ORDER_TYPE_TIME tt;
   datetime ex;
   GetExpiry(tt, ex);
   for(int i = 0; i < n; i++)
     {
      trade.SetTypeFilling(f[i]);
      bool ok;
      if(type == ORDER_TYPE_BUY_STOP)
         ok = trade.BuyStop(lot, price, _Symbol, sl, tp, tt, ex, "ScalperStar");
      else
         ok = trade.SellStop(lot, price, _Symbol, sl, tp, tt, ex, "ScalperStar");
      if(ok && RetOK(trade.ResultRetcode()))
        {
         g_failCount = 0;
         return(true);
        }
      if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_FILL)
         break;
     }
   OnFail(type == ORDER_TYPE_BUY_STOP ? "BuyStop" : "SellStop");
   return(false);
  }

bool SendMarket(const bool buy, const double lot, const double sl, const double tp)
  {
   ENUM_ORDER_TYPE_FILLING f[];
   int n = BuildFill(false, f);
   for(int i = 0; i < n; i++)
     {
      trade.SetTypeFilling(f[i]);
      bool ok = buy ? trade.Buy(lot, _Symbol, 0.0, sl, tp, "ScalperStar")
                    : trade.Sell(lot, _Symbol, 0.0, sl, tp, "ScalperStar");
      if(ok && RetOK(trade.ResultRetcode()))
        {
         g_failCount = 0;
         return(true);
        }
      if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_FILL)
         break;
     }
   OnFail(buy ? "Buy(market)" : "Sell(market)");
   return(false);
  }

bool ModifySL(const ulong ticket, const double sl, const double tp)
  {
   g_reqSent = true;
   if(trade.PositionModify(ticket, sl, tp) && RetOK(trade.ResultRetcode()))
      return(true);
   ModFail();
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

   if(!PlaceStop(ORDER_TYPE_BUY_STOP, bp, bsl, btp, lot))
      return(false);
   if(!PlaceStop(ORDER_TYPE_SELL_STOP, sp, ssl, stp, lot))
     {
      DeleteAllPendings(); // never leave a lone side (#3); cooldown already set
      return(false);
     }
   return(true);
  }

// #15: SL/TP measured from the real fill price, not from the pending price
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
   bool isBuy = (s.ptype == POSITION_TYPE_BUY);

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
void ManageTrail(const SSnap &s)
  {
   double d, sd, trail, tp;
   if(!GetDist(d, sd, trail, tp))
      return;
   double frz  = FreezeDist();
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double step = (double)MathMax(TrailStepPoints, 1) * _Point;

   if(s.ptype == POSITION_TYPE_BUY)
     {
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
         ManageTrail(s);
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
// -1 = history not updated yet (#7)
int LastCloseResult()
  {
   if(g_lastPosId == 0)
      return(-1);
   if(!HistorySelectByPosition((ulong)g_lastPosId))
      return(-1);
   int n = HistoryDealsTotal();
   for(int i = n - 1; i >= 0; i--)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT)
         continue;
      ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)HistoryDealGetInteger(dt, DEAL_REASON);
      return(rs == DEAL_REASON_SL ? 1 : 0);
     }
   return(-1);
  }

void ResetChain()
  {
   g_chain     = false;
   g_revCount  = 0;
   g_curTicket = 0;
   g_lastPosId = 0;
   g_waitSince = 0;
  }

// keep the opposite pending glued to the position SL
void SyncOpposite(const SSnap &s, const bool allowMod)
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

   double d, sd, tr, tpd;
   if(!GetDist(d, sd, tr, tpd))
      return;
   double minD = StopsDist();
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Position SL and the opposite stop share the same price basis
   // (Buy SL & Sell Stop -> Bid, Sell SL & Buy Stop -> Ask) => exact SL price.
   // Price is ALWAYS clamped to a valid distance (#11), otherwise the order is rejected.
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
      double want = ReverseLotRecalc ? CalcLot() : s.pvol; // #12
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
      PlaceStop(isBuy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP, P, pSL, pTP, lot);
      return;
     }

   ulong  tk     = isBuy ? s.tSellStop : s.tBuyStop;
   double cur    = isBuy ? s.pSellStop : s.pBuyStop;
   datetime cexp = isBuy ? s.expSell : s.expBuy;

   // expiry refresh before the pending times out
   ENUM_ORDER_TYPE_TIME tt;
   datetime ex;
   GetExpiry(tt, ex);
   bool refresh = (tt == ORDER_TIME_SPECIFIED && cexp > 0 &&
                   (long)(cexp - TimeTradeServer()) < (long)(PendingExpiryMin * 60) / 3);

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
   if(!(trade.OrderModify(tk, newP, pendSL, pendTP, tt, ex, 0.0) && RetOK(trade.ResultRetcode())))
      ModFail();
  }

// SL was hit but the opposite pending did not trigger: open reverse at market
void ReverseByMarket(const SSnap &s)
  {
   bool wasBuy = (g_lastType == POSITION_TYPE_BUY);
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

   ulong tk = wasBuy ? s.tSellStop : s.tBuyStop;
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
      g_chain     = true;
      g_lastType  = s.ptype;
      g_lastPosId = s.pid;
      g_chainLot  = s.pvol;
      g_waitSince = 0;

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
         // history not updated yet: retry for HistoryWaitMs before giving up (#7)
         if(g_waitSince == 0)
            g_waitSince = now;
         if(now - g_waitSince < (ulong)MathMax(HistoryWaitMs, 0))
            return;
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
            if(now - g_waitSince < (ulong)MathMax(GraceMs, 0))
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
   UpdateRisk();
   SSnap s;
   Scan(s);
   g_floating = s.floating;
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
//| Panel (updated at most once per second - #14)                    |
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
      if(s.ptype == POSITION_TYPE_BUY)
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

   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   SetVal(0, (Mode == SS_MODE_1) ? "Mode 1" : "Mode 2", clrAqua);
   SetVal(1, IntegerToString(spPts) + " pt / " + DoubleToString(spPips, 1) + " pip", sc);
   SetVal(2, stTxt, stClr);
   SetVal(3, DoubleToString(lot, 2), clrWhite);
   SetVal(4, (LotMode == SS_FIXED_LOT) ? "FIXED_LOT" : "EQUITY_LOT", clrOrange);
   SetVal(5, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " " + cur, clrWhite);
   SetVal(6, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + cur, clrWhite);
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
   if(!SymbolSelect(_Symbol, true))
      Print("ScalperStar: warning - SymbolSelect failed for ", _Symbol);

   if(PointsPerPip > 0)
      g_pip = (double)PointsPerPip * _Point;
   else
      g_pip = (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)MathMax(Slippage, 0));
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // information about account / symbol (#1, #2, #6)
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("ScalperStar: NETTING account detected - opposite fills net against each other; Mode 1/2 behave differently from hedging");
   Print(StringFormat("ScalperStar: %s digits=%d point=%s pip=%s stopsLevel=%d freezeLevel=%d minDist=%.1f pip",
                      _Symbol, _Digits, DoubleToString(_Point, _Digits), DoubleToString(g_pip, _Digits),
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
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
   RunLogic();
   UpdatePanel();
  }

// react immediately on fills (delete opposite pending / place reversal asap)
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.symbol == _Symbol)
      RunLogic();
  }
//+------------------------------------------------------------------+
