//+------------------------------------------------------------------+
//|                                                  ScalperStar.mq4 |
//|                  Stop-order scalper: Mode 1 / Mode 2 (v3.50)     |
//|            MT4 port of ScalperStar_v3_50.mq5 (hardened)         |
//+------------------------------------------------------------------+
#property copyright "ScalperStar"
#property version   "3.50"
#property description "ScalperStar - Buy Stop / Sell Stop scalper with trailing (Mode 1 & Mode 2 reversal), hardened - MT4"
#property strict

const string PFX = "ScalperStar_";
const string CMT = "ScalperStar";

//--- enums (prefixed to avoid name clashes)
enum ENUM_SS_MODE    { SS_MODE_1 = 1,       // Mode 1 (OCO breakout)
                       SS_MODE_2 = 2 };     // Mode 2 (reversal chain)
enum ENUM_SS_LOTMODE { SS_FIXED_LOT = 0,    // Fixed lot
                       SS_EQUITY_LOT = 1 }; // Equity based lot
enum ENUM_SS_STATE   { SS_IDLE = 0, SS_PENDING = 1, SS_IN_BUY = 2, SS_IN_SELL = 3 };

//--- inputs: Strategi
input ENUM_SS_MODE    Mode               = SS_MODE_1;     // Mode
input double          DistancePips       = 10.0;          // Jarak pending dari Bid/Ask (pips)
input double          SLPips             = 10.0;          // Stop Loss (pips)
input double          TrailPips          = 10.0;          // Trailing (pips)
input double          TPPips             = 0.0;           // Take Profit (pips), 0 = tanpa TP
input int             PointsPerPip       = 0;             // Point per 1 pip, 0 = otomatis (XAU/indeks: isi manual!)
input bool            AutoAdjustToMin    = true;          // Naikkan input ke minimum broker (false = berhenti + peringatan)
input bool            SpreadCompensation = true;          // Mode 2: tutup celah dengan market order bila pending tidak terpicu
input int             Slippage           = 10;            // Slippage (point)
input int             MaxSpreadPoints    = 0;             // Maks spread (point), 0 = nonaktif

//--- inputs: Lot & Margin
input ENUM_SS_LOTMODE LotMode            = SS_FIXED_LOT;  // Mode lot
input double          FixedLot           = 0.01;          // Lot dasar
input double          EquityPerLot       = 1000.0;        // Setiap kelipatan Equity ini lot naik
input double          LotStep            = 0.01;          // Kenaikan lot
input double          MaxLot             = 100.0;         // Lot maksimum
input bool            ReverseLotRecalc   = true;          // Mode 2: hitung ulang lot di tiap reversal
input double          MaxMarginUsePct    = 50.0;          // Maks margin terpakai (% equity), 0 = nonaktif
input int             MagicNumber        = 20260101;      // Magic Number

//--- inputs: Eksekusi aman
input int             StopsBufferPoints  = 3;             // Buffer di atas stops/freeze level (point)
input double          MinDistSpreadMult  = 3.0;           // Jarak pending minimum = N x spread
input int             CooldownMs         = 2000;          // Cooldown dasar setelah request gagal (ms)
input int             ModifyIntervalMs   = 300;           // Jeda minimum antar modify trailing/pending (ms)
input int             TrailStepPoints    = 5;             // Langkah minimum trailing (point)
input int             GraceMs            = 1500;          // Tahan cleanup saat 2 posisi muncul (ms)
input int             HistoryWaitMs      = 3000;          // Tunggu history order terupdate (ms)
input int             PendingExpiryMin   = 60;            // Expiry pending (menit), 0 = GTC

//--- inputs: Filter waktu / berita
input int             StopBeforeCloseMin = 10;            // Tidak buka siklus X menit sebelum sesi tutup, 0 = off
input bool            CloseOnFridayEnd   = false;         // Tutup semua posisi menjelang tutup sesi Jumat
input string          NewsTimes          = "";            // Jam berita (waktu server) "HH:MM,HH:MM"
input int             NewsBeforeMin      = 3;             // Berhenti X menit sebelum berita
input int             NewsAfterMin       = 3;             // Berhenti X menit sesudah berita
input double          SpikeFraction      = 0.6;           // Spike: gerak 1 detik >= N x jarak pending (0 = off)
input int             SpikePauseSec      = 5;             // Jeda siklus baru setelah spike (detik)

//--- inputs: Batas risiko
input double          MaxDailyLoss       = 0.0;           // Batas rugi harian (mata uang akun), 0 = off
input int             MaxReversals       = 0;             // Mode 2: maks reversal per rantai, 0 = off
input int             PauseAfterLimitMin = 5;             // Jeda setelah batas reversal tercapai (menit)

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

// millisecond clock (GetTickCount wrap-safe)
uint               g_lastTick   = 0;
ulong              g_msAcc      = 1000000;

// chain (Mode 2)
bool               g_chain      = false;
int                g_lastType   = OP_BUY;
int                g_curTicket  = 0;
int                g_curType    = OP_BUY;
int                g_lastPosId  = 0;
int                g_revCount   = 0;
bool               g_limitHit   = false;
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
bool               g_noExpiry     = false;

// guards
bool               g_noStart    = false;
bool               g_noChain    = false;
bool               g_flatten    = false;
string             g_blockWhy   = "";
ulong              g_pauseUntil = 0;
string             g_pauseWhy   = "";
int                g_news[];

// risk
bool               g_halt       = false;
datetime           g_day        = 0;
double             g_dayPL      = 0.0;
double             g_floating   = 0.0;
ulong              g_riskMs     = 0;

// misc
ulong              g_panelMs    = 0;
bool               g_inLogic    = false;
bool               g_dup        = false;
double             g_lockMe     = 0.0;
ulong              g_lockMs     = 0;
ulong              g_warnMs     = 0;
string             g_lastWarn   = "";
ulong              g_winStart   = 0;
double             g_winHi      = 0.0;
double             g_winLo      = 0.0;

//+------------------------------------------------------------------+
//| Time helpers (tick-time in tester, so throttles behave the same) |
//+------------------------------------------------------------------+
ulong NowMs()
  {
   if(g_tester)
      return((ulong)TimeCurrent() * 1000);
   uint t = GetTickCount();
   g_msAcc += (ulong)((uint)(t - g_lastTick));
   g_lastTick = t;
   return(g_msAcc);
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
string ErrTxt(const int e)
  {
   switch(e)
     {
      case 0:    return("ok");
      case 1:    return("no change");
      case 2:    return("common error");
      case 3:    return("invalid parameters");
      case 4:    return("server busy");
      case 6:    return("no connection");
      case 8:    return("too frequent requests");
      case 64:   return("account disabled");
      case 65:   return("invalid account");
      case 128:  return("trade timeout");
      case 129:  return("invalid price");
      case 130:  return("invalid stops");
      case 131:  return("invalid volume");
      case 132:  return("market closed");
      case 133:  return("trade disabled");
      case 134:  return("not enough money");
      case 135:  return("price changed");
      case 136:  return("off quotes");
      case 137:  return("broker busy");
      case 138:  return("requote");
      case 139:  return("order locked");
      case 140:  return("long only");
      case 141:  return("too many requests");
      case 145:  return("modification denied (freeze level)");
      case 146:  return("trade context busy");
      case 147:  return("expiration denied");
      case 148:  return("too many orders");
      case 149:  return("hedging prohibited");
      case 150:  return("FIFO rule prohibits");
      case 4108: return("invalid ticket");
      case 4109: return("trade not allowed");
      case 4110: return("longs not allowed");
      case 4111: return("shorts not allowed");
     }
   return("error " + IntegerToString(e));
  }

int SlipPts()
  {
   return(Slippage > 0 ? Slippage : 0);
  }

double BidP()
  {
   return(MarketInfo(_Symbol, MODE_BID));
  }

double AskP()
  {
   return(MarketInfo(_Symbol, MODE_ASK));
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

// failure of an order/close request -> cooldown with back-off
void OnFail(const string ctx)
  {
   int rc = g_lastErr;
   g_failCount++;
   ulong cd = (ulong)MathMax(CooldownMs, 200) * (ulong)MathMin(g_failCount, 5);
   if(rc == 133 || rc == 134 || rc == 132 || rc == 140 || rc == 148 || rc == 149 || rc == 150 ||
      rc == 64 || rc == 65 || rc == 4109 || rc == 4110 || rc == 4111)
     {
      if(cd < 30000)
         cd = 30000;
     }
   else
      if((rc == 141 || rc == 8) && cd < 5000)
         cd = 5000;
   Cool(cd);
   Print(StringFormat("ScalperStar: %s failed err=%d (%s), cooldown %I64u ms",
                      ctx, rc, ErrTxt(rc), cd));
  }

void ModFail()
  {
   int rc = g_lastErr;
   ulong cd = (ulong)((rc == 145 || rc == 141 || rc == 8) ? 3000 : 1000);
   g_modFailUntil = NowMs() + cd;
   Warn(StringFormat("modify failed err=%d (%s)", rc, ErrTxt(rc)));
  }

bool ModDue()
  {
   ulong now = NowMs();
   if(now < g_modFailUntil)
      return(false);
   return(now - g_lastModMs >= (ulong)MathMax(ModifyIntervalMs, 0));
  }

// minimum distance: max(stops, freeze) + buffer
double StopsDist()
  {
   int sl = (int)MarketInfo(_Symbol, MODE_STOPLEVEL);
   int fr = (int)MarketInfo(_Symbol, MODE_FREEZELEVEL);
   int mx = (sl > fr) ? sl : fr;
   int bf = (StopsBufferPoints > 1) ? StopsBufferPoints : 1;
   return((double)(mx + bf) * _Point);
  }

double FreezeDist()
  {
   return(MarketInfo(_Symbol, MODE_FREEZELEVEL) * _Point);
  }

int LotDigits()
  {
   double st = MarketInfo(_Symbol, MODE_LOTSTEP);
   if(st <= 0.0)
      st = 0.01;
   int d = 0;
   while(d < 8 && MathAbs(st * MathPow(10.0, d) - MathRound(st * MathPow(10.0, d))) > 1e-9)
      d++;
   return(d);
  }

double NormLot(double lot)
  {
   double step = MarketInfo(_Symbol, MODE_LOTSTEP);
   double vmin = MarketInfo(_Symbol, MODE_MINLOT);
   double vmax = MarketInfo(_Symbol, MODE_MAXLOT);
   if(step <= 0.0)
      step = 0.01;
   double cap = vmax;
   if(MaxLot > 0.0 && (cap <= 0.0 || MaxLot < cap))
      cap = MaxLot;
   if(cap > 0.0 && lot > cap)
      lot = cap;
   lot = MathFloor(lot / step + 1e-8) * step;
   if(lot < vmin)
      lot = vmin;
   return(NormalizeDouble(lot, LotDigits()));
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
   if(MaxMarginUsePct > 0.0)
     {
      double byPct = AccountEquity() * MaxMarginUsePct / 100.0 - AccountMargin();
      room = MathMin(room, byPct);
     }
   if(room <= 0.0)
      return(0.0);
   int    sd     = (sides > 1) ? sides : 1;
   double maxLot = room / (mpl * (double)sd);
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
   return(NormalizeDouble(lot, LotDigits()));
  }

bool SpreadOK()
  {
   double ask = AskP();
   double bid = BidP();
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
      return(false);
   if(MaxSpreadPoints <= 0)
      return(true);
   int sp = (int)MathRound((ask - bid) / _Point);
   return(sp <= MaxSpreadPoints);
  }

// trading permissions
bool CanTradeNow(string &why)
  {
   if(!IsTradeAllowed())
     { why = "AutoTrading OFF / EA trading not allowed"; return(false); }
   if(!g_tester && !IsConnected())
     { why = "No connection to server"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { why = "Account trading disabled"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { why = "Experts disabled for account"; return(false); }
   if(MarketInfo(_Symbol, MODE_TRADEALLOWED) == 0.0)
     { why = "Trading not allowed on symbol / market closed"; return(false); }
   double ask = AskP();
   double bid = BidP();
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
     { why = "Invalid quotes"; return(false); }
   why = "";
   return(true);
  }

// effective distances; warns when inputs are below broker minimum
bool GetDist(double &d, double &sd, double &tr, double &tp)
  {
   double ask  = AskP();
   double bid  = BidP();
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
      if(!AutoAdjustToMin)
        {
         Warn("input below broker minimum, trading paused:" + w);
         return(false);
        }
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
   double ask  = AskP();
   double bid  = BidP();
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

// pending expiry (0 = GTC). Falls back to GTC permanently if broker denies expiration.
datetime GetExpiry()
  {
   if(PendingExpiryMin <= 0 || g_noExpiry)
      return(0);
   return(TimeCurrent() + (datetime)(PendingExpiryMin * 60));
  }

//+------------------------------------------------------------------+
//| Guards: news, session, spike, duplicate, daily loss              |
//+------------------------------------------------------------------+
void ParseNews()
  {
   ArrayResize(g_news, 0);
   string parts[];
   int n = StringSplit(NewsTimes, (ushort)',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      int pos = StringFind(p, ":");
      if(pos < 1)
         continue;
      int h = (int)StringToInteger(StringSubstr(p, 0, pos));
      int m = (int)StringToInteger(StringSubstr(p, pos + 1));
      if(h < 0 || h > 23 || m < 0 || m > 59)
         continue;
      int k = ArraySize(g_news);
      ArrayResize(g_news, k + 1);
      g_news[k] = h * 60 + m;
     }
  }

bool InNewsWindow()
  {
   int n = ArraySize(g_news);
   if(n == 0)
      return(false);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int mnow = dt.hour * 60 + dt.min;
   int bef  = (NewsBeforeMin > 0) ? NewsBeforeMin : 0;
   int aft  = (NewsAfterMin > 0) ? NewsAfterMin : 0;
   for(int i = 0; i < n; i++)
     {
      int d = mnow - g_news[i];
      if(d > 720)
         d -= 1440;
      if(d < -720)
         d += 1440;
      if(d >= -bef && d <= aft)
         return(true);
     }
   return(false);
  }

// true = inside a trade session; secToEnd = seconds until continuous session ends
bool SessionInfo(int &secToEnd, int &dow)
  {
   secToEnd = INT_MAX;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dow = dt.day_of_week;
   int secNow = dt.hour * 3600 + dt.min * 60 + dt.sec;
   bool any = false;
   for(int i = 0; i < 16; i++)
     {
      datetime from = 0, to = 0;
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
         break;
      any = true;
      int f = (int)from;
      int t = (int)to;
      if(secNow >= f && secNow < t)
        {
         int total = t - secNow;
         int d = dt.day_of_week;
         for(int k = 0; k < 7 && t >= 86400; k++)
           {
            d = (d + 1) % 7;
            bool cont = false;
            for(int j = 0; j < 16; j++)
              {
               datetime f2 = 0, t2 = 0;
               if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, j, f2, t2))
                  break;
               if((int)f2 == 0)
                 {
                  total += (int)t2;
                  t = (int)t2;
                  cont = true;
                  break;
                 }
              }
            if(!cont)
               break;
           }
         secToEnd = total;
         return(true);
        }
     }
   if(!any)
      return(true); // no session data (e.g. tester) -> assume open
   return(false);
  }

void RefreshGuards()
  {
   g_noStart  = false;
   g_noChain  = false;
   g_flatten  = false;
   g_blockWhy = "";

   if(g_dup)
     {
      g_noStart = true; g_noChain = true; g_blockWhy = "Duplicate EA";
      return;
     }
   if(g_halt)
     {
      g_noStart = true; g_noChain = true; g_blockWhy = "Daily loss limit";
      return;
     }
   if(InNewsWindow())
     {
      g_noStart = true; g_noChain = true; g_blockWhy = "News window";
     }
   int sec = INT_MAX, dow = 0;
   bool inSess = SessionInfo(sec, dow);
   if(!inSess)
     {
      g_noStart = true; g_noChain = true; g_blockWhy = "Market closed";
     }
   else
      if(StopBeforeCloseMin > 0 && sec < StopBeforeCloseMin * 60)
        {
         g_noStart = true; g_noChain = true; g_blockWhy = "Near session end";
         if(CloseOnFridayEnd && dow == 5)
            g_flatten = true;
        }
   if(!g_noStart && NowMs() < g_pauseUntil)
     {
      g_noStart = true;
      g_blockWhy = "Pause: " + g_pauseWhy;
     }
  }

// fast move detector: pauses NEW cycles only
void SpikeCheck()
  {
   if(SpikeFraction <= 0.0 || SpikePauseSec <= 0)
      return;
   double bid = BidP();
   if(bid <= 0.0)
      return;
   ulong now = NowMs();
   if(g_winStart == 0 || now - g_winStart >= 1000)
     {
      g_winStart = now;
      g_winHi = bid;
      g_winLo = bid;
      return;
     }
   if(bid > g_winHi)
      g_winHi = bid;
   if(bid < g_winLo)
      g_winLo = bid;
   double dist = MathMax(DistancePips * g_pip, StopsDist());
   if(g_winHi - g_winLo >= SpikeFraction * dist)
     {
      ulong u = now + (ulong)SpikePauseSec * 1000;
      if(u > g_pauseUntil)
        {
         g_pauseUntil = u;
         g_pauseWhy = "Spike";
        }
      g_winStart = 0;
     }
  }

string LockName()
  {
   return("SS_LOCK_" + IntegerToString(AccountNumber()) + "_" + _Symbol + "_" +
          IntegerToString(MagicNumber));
  }

// two charts, same symbol + magic
bool AcquireLock()
  {
   g_lockMe = (double)(ChartID() % 1000000000) + 1.0;
   if(g_tester)
      return(true);
   string n = LockName();
   if(GlobalVariableCheck(n) && GlobalVariableCheck(n + "_T"))
     {
      double owner = GlobalVariableGet(n);
      double ts    = GlobalVariableGet(n + "_T");
      if(owner != g_lockMe && ((double)TimeLocal() - ts) < 15.0)
         return(false);
     }
   GlobalVariableSet(n, g_lockMe);
   GlobalVariableSet(n + "_T", (double)TimeLocal());
   return(true);
  }

void CheckLock()
  {
   if(g_tester)
      return;
   string n = LockName();
   double owner = GlobalVariableCheck(n) ? GlobalVariableGet(n) : 0.0;
   double ts    = GlobalVariableCheck(n + "_T") ? GlobalVariableGet(n + "_T") : 0.0;
   double nowl  = (double)TimeLocal();
   if(owner != 0.0 && owner != g_lockMe && (nowl - ts) < 15.0)
     {
      if(!g_dup)
         Print("ScalperStar: another EA instance uses the same symbol + Magic Number - trading blocked");
      g_dup = true;
      return;
     }
   g_dup = false;
   GlobalVariableSet(n, g_lockMe);
   GlobalVariableSet(n + "_T", nowl);
  }

void ReleaseLock()
  {
   if(g_tester)
      return;
   string n = LockName();
   if(GlobalVariableCheck(n) && GlobalVariableGet(n) == g_lockMe)
     {
      GlobalVariableDel(n);
      GlobalVariableDel(n + "_T");
     }
  }

// daily P/L (realized by this symbol+magic + floating) and loss limit
void UpdateRisk()
  {
   ulong now = NowMs();
   if(g_riskMs != 0 && now - g_riskMs < 1000)
      return;
   g_riskMs = now;

   datetime t = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day0 = StructToTime(dt);
   if(day0 != g_day)
     {
      g_day = day0;
      g_halt = false;
     }

   double realized = 0.0;
   int    older    = 0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      datetime ct = OrderCloseTime();
      if(ct < day0)
        {
         older++;
         if(older > 300)
            break;
         continue;
        }
      older = 0;
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
   if(MaxDailyLoss > 0.0 && !g_halt && g_dayPL <= -MaxDailyLoss)
     {
      g_halt = true;
      Print(StringFormat("ScalperStar: daily loss limit reached (%.2f) - positions closed, trading stopped until next day", g_dayPL));
     }
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
      int ty = OrderType();
      int t  = OrderTicket();
      if(ty == OP_BUY || ty == OP_SELL)
        {
         double pr = OrderProfit() + OrderSwap() + OrderCommission();
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
            s.ptype = ty;
            s.popen = OrderOpenPrice();
            s.psl   = OrderStopLoss();
            s.ptp   = OrderTakeProfit();
            s.pvol  = OrderLots();
           }
        }
      else
         if(ty == OP_BUYSTOP)
           {
            s.nBuyStop++;
            s.tBuyStop = t;
            s.pBuyStop = OrderOpenPrice();
            s.expBuy   = OrderExpiration();
           }
         else
            if(ty == OP_SELLSTOP)
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
// true = the pending order is gone (deleted, expired or already triggered)
bool DeleteOrder(const int ticket)
  {
   for(int a = 0; a < 3; a++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         return(true);
      if(OrderCloseTime() > 0)
         return(true);
      if(OrderType() <= OP_SELL)
         return(true); // triggered -> now a position
      ResetLastError();
      if(OrderDelete(ticket))
         return(true);
      g_lastErr = GetLastError();
      if(g_lastErr == 146 && !g_tester)
         Sleep(100);
     }
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(true);
   if(OrderCloseTime() > 0)
      return(true);
   return(OrderType() <= OP_SELL);
  }

bool DeleteAllPendings()
  {
   ulong now = NowMs();
   if(now < g_delFailUntil)
      return(false);
   bool ok = true;
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
      int t = OrderTicket();
      if(!DeleteOrder(t))
         ok = false;
     }
   if(!ok)
     {
      g_delFailUntil = now + 1000;
      Warn(StringFormat("delete pending failed err=%d (%s)", g_lastErr, ErrTxt(g_lastErr)));
     }
   return(ok);
  }

bool ClosePos(const int ticket)
  {
   for(int a = 0; a < 3; a++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         return(true);
      if(OrderCloseTime() > 0)
         return(true);
      int ty = OrderType();
      if(ty > OP_SELL)
         return(true);
      double lots = OrderLots();
      RefreshRates();
      double price = NormalizeDouble((ty == OP_BUY) ? BidP() : AskP(), _Digits);
      ResetLastError();
      if(OrderClose(ticket, lots, price, SlipPts(), clrNONE))
         return(true);
      g_lastErr = GetLastError();
      if(g_lastErr == 135 || g_lastErr == 136 || g_lastErr == 137 || g_lastErr == 138)
         continue; // price moved / requote -> retry with fresh price
      if(g_lastErr == 146 && !g_tester)
        {
         Sleep(100);
         continue;
        }
      break;
     }
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(true);
   if(OrderCloseTime() > 0)
      return(true);
   OnFail("OrderClose");
   return(false);
  }

// close all own positions except 'keep' (keep = 0 -> close all)
void CloseAllExcept(const int keep)
  {
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
      if(!ClosePos(t))
         break; // failure -> cooldown, do not spam
     }
  }

// two positions at once. Wait GraceMs (SL may close the old one), then
// Mode 2 keeps the NEWEST position (reversal chain survives), Mode 1 keeps the best.
void HandleExtras(SSnap &s)
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
   int keep = (Mode == SS_MODE_2) ? s.pticket : s.tBest;
   CloseAllExcept(keep);
   if(s.nBuyStop + s.nSellStop + s.nOther > 0)
      DeleteAllPendings();
  }

bool PlaceStop(const int type, const double price, const double sl, const double tp, const double lot)
  {
   for(int a = 0; a < 3; a++)
     {
      datetime ex = GetExpiry();
      ResetLastError();
      int tk = OrderSend(_Symbol, type, lot, price, SlipPts(), sl, tp, CMT, MagicNumber, ex,
                         (type == OP_BUYSTOP) ? clrLime : clrTomato);
      if(tk >= 0)
        {
         g_failCount = 0;
         return(true);
        }
      g_lastErr = GetLastError();
      if(g_lastErr == 147 && ex != 0)
        {
         g_noExpiry = true;
         Warn("broker denies pending expiration - using GTC (pendings can survive the weekend)");
         continue;
        }
      if(g_lastErr == 146 && !g_tester)
        {
         Sleep(100);
         continue;
        }
      break;
     }
   OnFail(type == OP_BUYSTOP ? "BuyStop" : "SellStop");
   return(false);
  }

bool SendMarket(const bool buy, const double lot, const double sl, const double tp)
  {
   int  ty = buy ? OP_BUY : OP_SELL;
   bool useStops = true;
   for(int a = 0; a < 4; a++)
     {
      RefreshRates();
      double price = NormalizeDouble(buy ? AskP() : BidP(), _Digits);
      double xs = useStops ? sl : 0.0;
      double xt = useStops ? tp : 0.0;
      ResetLastError();
      int tk = OrderSend(_Symbol, ty, lot, price, SlipPts(), xs, xt, CMT, MagicNumber, 0,
                         buy ? clrLime : clrTomato);
      if(tk >= 0)
        {
         g_failCount = 0;
         return(true);   // if SL/TP were dropped, FixInitialSL() sets them next
        }
      g_lastErr = GetLastError();
      if(g_lastErr == 135 || g_lastErr == 136 || g_lastErr == 137 || g_lastErr == 138)
         continue;
      if(g_lastErr == 130 && useStops && (sl > 0.0 || tp > 0.0))
        {
         useStops = false; // broker refuses SL/TP in market order -> open, then set via modify
         continue;
        }
      if(g_lastErr == 146 && !g_tester)
        {
         Sleep(100);
         continue;
        }
      break;
     }
   OnFail(buy ? "Buy(market)" : "Sell(market)");
   return(false);
  }

bool ModifySL(const int ticket, const double sl, const double tp)
  {
   g_reqSent = true;
   if(OrderSelect(ticket, SELECT_BY_TICKET))
     {
      ResetLastError();
      if(OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(sl, _Digits),
                     NormalizeDouble(tp, _Digits), 0, clrNONE))
         return(true);
      g_lastErr = GetLastError();
      if(g_lastErr == 1)
         return(true); // nothing changed
     }
   else
      g_lastErr = GetLastError();
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
   RefreshRates();
   double ask = AskP();
   double bid = BidP();

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
      DeleteAllPendings(); // never leave a lone side; cooldown already set
      return(false);
     }
   return(true);
  }

// SL/TP measured from the real fill price, not from the pending price
void FixInitialSL(SSnap &s)
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
   double bid = BidP();
   double ask = AskP();
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
void ManageTrail(SSnap &s)
  {
   double d, sd, trail, tp;
   if(!GetDist(d, sd, trail, tp))
      return;
   double frz  = FreezeDist();
   double bid  = BidP();
   double ask  = AskP();
   double step = (double)((TrailStepPoints > 1) ? TrailStepPoints : 1) * _Point;

   if(s.ptype == OP_BUY)
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
void RunMode1(SSnap &s)
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
   if(g_noChain)
     {
      if(np > 0)
         DeleteAllPendings(); // news / session end / halt: do not stay armed
      return;
     }
   if(s.nBuyStop == 1 && s.nSellStop == 1 && s.nOther == 0)
      return; // PENDING
   if(np > 0)
     {
      DeleteAllPendings(); // abnormal -> restart
      return;
     }
   if(g_noStart || Cooling())
      return;
   StartCycle();
  }

//+------------------------------------------------------------------+
//| MODE 2                                                           |
//+------------------------------------------------------------------+
// 1 = last chain position closed by SL, 0 = closed by something else,
// -1 = history not updated yet
// MT4 has no deal reason: detect via broker comment "[sl]"/"[tp]", else by close price vs SL/TP
int LastCloseResult()
  {
   if(g_lastPosId <= 0)
      return(-1);
   if(!OrderSelect(g_lastPosId, SELECT_BY_TICKET))
      return(-1);
   if(OrderCloseTime() == 0)
      return(-1);
   int ty = OrderType();
   if(ty != OP_BUY && ty != OP_SELL)
      return(0);
   string cm = OrderComment();
   if(StringFind(cm, "[sl]") >= 0)
      return(1);
   if(StringFind(cm, "[tp]") >= 0)
      return(0);
   double sl = OrderStopLoss();
   if(sl <= 0.0)
      return(0);
   double tp  = OrderTakeProfit();
   double cp  = OrderClosePrice();
   double tol = (double)(SlipPts() + 1) * _Point;
   if(ty == OP_BUY)
     {
      if(tp > 0.0 && cp >= tp - tol)
         return(0);
      return(cp <= sl + tol ? 1 : 0);
     }
   if(tp > 0.0 && cp <= tp + tol)
      return(0);
   return(cp >= sl - tol ? 1 : 0);
  }

void ResetChain()
  {
   g_chain     = false;
   g_revCount  = 0;
   g_curTicket = 0;
   g_lastPosId = 0;
   g_waitSince = 0;
   g_limitHit  = false;
  }

// keep the opposite pending glued to the position SL
void SyncOpposite(SSnap &s, const bool allowMod)
  {
   bool isBuy = (s.ptype == OP_BUY);
   int  nOpp  = isBuy ? s.nSellStop : s.nBuyStop;
   int  nBad  = isBuy ? (s.nBuyStop + s.nOther) : (s.nSellStop + s.nOther);
   int  nAll  = s.nBuyStop + s.nSellStop + s.nOther;

   bool limit = (MaxReversals > 0 && g_revCount >= MaxReversals);
   if(g_noChain || limit)
     {
      if(limit)
         g_limitHit = true;
      if(nAll > 0)
         DeleteAllPendings(); // chain stops here, SL/trailing still protect the position
      return;
     }
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
   double bid  = BidP();
   double ask  = AskP();

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
   bool refresh = (ex != 0 && cexp > 0 &&
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
   ResetLastError();
   if(!OrderModify(tk, NormalizeDouble(newP, _Digits), pendSL, pendTP, ex, clrNONE))
     {
      g_lastErr = GetLastError();
      if(g_lastErr != 1)
         ModFail();
     }
  }

// SL was hit but the opposite pending did not trigger: open reverse at market
void ReverseByMarket(SSnap &s)
  {
   bool wasBuy = (g_lastType == OP_BUY);
   if((wasBuy && s.nSellStop != 1) || (!wasBuy && s.nBuyStop != 1))
     {
      DeleteAllPendings();
      ResetChain();
      return;
     }
   bool limit = (MaxReversals > 0 && g_revCount >= MaxReversals);
   if(g_noChain || limit)
     {
      if(limit)
         g_limitHit = true;
      DeleteAllPendings(); // next tick: no pending -> chain end handled in RunMode2
      return;
     }
   if(Cooling())
      return;

   double bid = BidP();
   double ask = AskP();

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
   RefreshRates();
   bid = BidP();
   ask = AskP();

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

void RunMode2(SSnap &s)
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
      g_lastPosId = s.pticket;
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
      if(g_limitHit)
        {
         ulong u = now + (ulong)MathMax(PauseAfterLimitMin, 0) * 60000;
         if(u > g_pauseUntil)
           {
            g_pauseUntil = u;
            g_pauseWhy = "Max reversals";
           }
         Print("ScalperStar: max reversals reached - chain finished, pausing new cycles");
        }
      ResetChain();
      if(g_noStart || Cooling())
         return;
      StartCycle();
      return;
     }
   if(g_noChain)
     {
      DeleteAllPendings();
      ResetChain();
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
   RefreshGuards();
   SSnap s;
   Scan(s);
   g_floating = s.floating;
   if(s.nPos <= 1)
      g_extraSince = 0;

   if(g_halt || g_flatten)
     {
      if(s.nPos > 0 && !Cooling())
         CloseAllExcept(0);
      if(s.nBuyStop + s.nSellStop + s.nOther > 0)
         DeleteAllPendings();
      ResetChain();
      return;
     }
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

   double bid = BidP();
   double ask = AskP();
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
   if(g_blockWhy != "")
     {
      info = g_blockWhy;
      ic = clrOrange;
     }
   else
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
   g_tester   = (bool)IsTesting();
   g_lastTick = GetTickCount();
   g_msAcc    = 1000000;

   if(DistancePips <= 0.0 || SLPips <= 0.0 || TrailPips <= 0.0 || FixedLot <= 0.0 ||
      TPPips < 0.0 || MaxDailyLoss < 0.0 || MaxReversals < 0 || PointsPerPip < 0 ||
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

   if(!AcquireLock())
     {
      Print("ScalperStar: another EA instance already uses ", _Symbol, " with Magic ", MagicNumber,
            " - change the Magic Number or remove the other instance");
      return(INIT_FAILED);
     }

   ParseNews();

   Print("ScalperStar: MT4 build - account must allow hedging (Mode 1/2 hold opposite orders); FIFO/NFA accounts will reject (err 149/150)");
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

   g_panelOn = !(g_tester && !(bool)IsVisualMode());
   if(g_panelOn)
      CreatePanel();
   if(!EventSetMillisecondTimer(250))
      EventSetTimer(1);
   UpdatePanel();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ReleaseLock();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
  }

void OnTick()
  {
   SpikeCheck();
   RunLogic();
   UpdatePanel();
  }

// MT4 has no OnTradeTransaction: the fast timer replaces it
// (delete opposite pending / place reversal asap after a fill)
void OnTimer()
  {
   ulong now = NowMs();
   if(g_lockMs == 0 || now - g_lockMs >= 1000)
     {
      g_lockMs = now;
      CheckLock();
     }
   RunLogic();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
