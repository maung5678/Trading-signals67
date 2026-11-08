//+------------------------------------------------------------------+
//|                                                  ST_TP_SL_EA.mq5 |
//|  Expert Advisor port of indicators/ST_with_TP_SL.pine            |
//|                                                                  |
//|  Signal : Supertrend flips direction on a CLOSED candle          |
//|           (same math as TradingView ta.supertrend / ta.dmi).     |
//|  Order  : market BUY/SELL on the next candle with                |
//|           SL = ATR x multiplier, TP1/TP2/TP3 = SL distance x R.  |
//|  Hedging accounts : the volume is split into up to three         |
//|           positions, each with its own TP (TP1, TP2, TP3) and    |
//|           the same SL, so the broker closes them server-side.    |
//|  Netting accounts : one position with SL and the furthest TP;    |
//|           the EA closes the TP1/TP2 parts itself.                |
//+------------------------------------------------------------------+
#property copyright   "Trading-signals67"
#property version     "1.00"
#property description "Supertrend TP/SL EA: BUY/SELL on Supertrend flips (closed candles only) with ATR-based SL and TP1-TP3."

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,        // ล็อตคงที่ (รวมทุก TP)
   LOT_RISK_PERCENT = 1  // เสี่ยง % ของบาลานซ์ต่อเทรด
  };

enum ENUM_OPPOSITE_MODE
  {
   OPPOSITE_ON_SIGNAL = 0, // ปิดเมื่อมีสัญญาณฝั่งตรงข้ามที่ผ่านตัวกรอง (เหมือนอินดิเคเตอร์)
   OPPOSITE_ON_FLIP = 1,   // ปิดทุกครั้งที่ Supertrend กลับทิศ (แม้ตัวกรองไม่ให้เข้า)
   OPPOSITE_NEVER = 2      // ไม่ปิด ปล่อยให้ชน SL / TP เอง
  };

//--- Signal (keep identical to the TradingView indicator settings)
input group "สัญญาณ (ตั้งให้ตรงกับอินดิเคเตอร์)"
input double          InpFactor        = 2.5;            // Factor (ตัวคูณ Supertrend)
input int             InpAtrPeriod     = 14;             // ATR (จำนวนแท่ง)
input ENUM_TIMEFRAMES InpSignalTf      = PERIOD_CURRENT; // TF ของสัญญาณ (CURRENT = TF ของกราฟ)
input int             InpHistoryBars   = 1000;           // จำนวนแท่งย้อนหลังที่ใช้คำนวณ

//--- Filters
input group "ตัวกรองสัญญาณ"
input bool            InpUseAdxFilter  = false;          // เข้าเฉพาะตอน ADX แรง
input double          InpAdxMin        = 25.0;           // เกณฑ์ ADX (ต้องสูงกว่าค่านี้)
input int             InpAdxLength     = 14;             // ADX: ความยาว DI
input int             InpAdxSmoothing  = 14;             // ADX: การปรับเรียบ
input ENUM_TIMEFRAMES InpHtfFilterTf   = PERIOD_CURRENT; // กรองด้วยเทรนด์ TF ใหญ่ (CURRENT = ไม่ใช้)
input bool            InpAllowBuy      = true;           // อนุญาตฝั่ง BUY
input bool            InpAllowSell     = true;           // อนุญาตฝั่ง SELL
input int             InpMaxSpreadPts  = 0;              // สเปรดสูงสุด (points, 0 = ไม่จำกัด)
input int             InpMaxDelayPct   = 50;             // เข้าได้ภายในกี่ % ของแท่งหลังสัญญาณปิด

//--- SL / TP
input group "จุด SL / TP"
input double          InpSlAtrMult     = 1.5;            // SL = ATR ×
input double          InpTp1R          = 1.0;            // TP1 (R)
input double          InpTp2R          = 2.0;            // TP2 (R)
input double          InpTp3R          = 3.0;            // TP3 (R)

//--- Position size
input group "ขนาดออเดอร์"
input ENUM_LOT_MODE   InpLotMode       = LOT_FIXED;      // วิธีคิดล็อต
input double          InpFixedLots     = 0.03;           // ล็อตรวม (โหมดล็อตคงที่)
input double          InpRiskPercent   = 1.0;            // เสี่ยง % ต่อเทรด (โหมดเสี่ยง %)
input double          InpMaxTotalLots  = 0.0;            // ล็อตรวมสูงสุด (0 = ไม่จำกัด)
input double          InpPart1Pct      = 34.0;           // สัดส่วนปิดที่ TP1 (%)
input double          InpPart2Pct      = 33.0;           // สัดส่วนปิดที่ TP2 (%)
input double          InpPart3Pct      = 33.0;           // สัดส่วนปิดที่ TP3 (%)

//--- Trade management
input group "บริหารออเดอร์"
input ENUM_OPPOSITE_MODE InpOppositeMode = OPPOSITE_ON_SIGNAL; // ออเดอร์เดิมเมื่อเทรนด์กลับ
input bool            InpBeAfterTp1    = false;          // ถึง TP1 แล้วเลื่อน SL ไปจุดเข้า (กันทุน)
input int             InpBeOffsetPts   = 0;              // กันทุนบวกเพิ่ม (points)
input bool            InpSlToTp1AfterTp2 = false;        // ถึง TP2 แล้วเลื่อน SL ไป TP1

//--- Misc
input group "อื่น ๆ"
input ulong           InpMagic         = 670067;         // Magic number (แยกออเดอร์ของ EA)
input int             InpSlippagePts   = 30;             // Slippage สูงสุด (points)
input bool            InpPushNotify    = true;           // ส่งแจ้งเตือนเข้าแอป MT5 มือถือ
input bool            InpAlertPopup    = false;          // แสดง Alert popup บนคอม
input bool            InpShowPanel     = true;           // แสดงสถานะมุมซ้ายบนของกราฟ

//--- Globals
CTrade   g_trade;
bool     g_netting            = false;
datetime g_lastBarTime        = 0;
datetime g_modifyBlockedUntil = 0;
int      g_lastDir            = 0;
double   g_lastSt             = EMPTY_VALUE;
double   g_lastAdx            = EMPTY_VALUE;
int      g_lastHtfDir         = 0;
string   g_lastEvent          = "-";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SignalTf()
  {
   return InpSignalTf == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTf;
  }

bool HtfFilterOn()
  {
   return InpHtfFilterTf != PERIOD_CURRENT && PeriodSeconds(InpHtfFilterTf) > PeriodSeconds(SignalTf());
  }

string TfName(const ENUM_TIMEFRAMES tf)
  {
   ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   return StringSubstr(EnumToString(t), 7);   // "PERIOD_M15" -> "M15"
  }

string Fmt(const double price)
  {
   return DoubleToString(price, _Digits);
  }

string DirText(const int dir)
  {
   return dir < 0 ? "ขาขึ้น ▲" : dir > 0 ? "ขาลง ▼" : "ไม่ทราบ";
  }

double NormPrice(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0)
      price = MathRound(price / tick) * tick;
   return NormalizeDouble(price, _Digits);
  }

string GvPrefix()
  {
   return "ST67_" + IntegerToString((long)InpMagic) + "_";
  }

string GvPositionKey(const ulong ticket)
  {
   return GvPrefix() + "P" + IntegerToString((long)ticket);
  }

string GvLastSignalKey()
  {
   return GvPrefix() + _Symbol + "_" + TfName(SignalTf()) + "_LAST";
  }

double GvGet(const string name, const double fallback)
  {
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : fallback;
  }

void Notify(const string msg, const bool push = true)
  {
   Print(msg);
   g_lastEvent = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + msg;
   if(!push)
      return;
   if(InpAlertPopup)
      Alert(msg);
   if(InpPushNotify && !MQLInfoInteger(MQL_TESTER))
      SendNotification(StringSubstr(msg, 0, 255));
  }

//+------------------------------------------------------------------+
//| Indicator math (mirrors TradingView ta.atr / ta.supertrend /     |
//| ta.dmi, same as bot/deriv_signal_bot.py). Arrays: index 0 = the  |
//| oldest candle.                                                   |
//+------------------------------------------------------------------+
bool LoadRates(const ENUM_TIMEFRAMES tf, MqlRates &rates[])
  {
   ArraySetAsSeries(rates, false);
   int need = MathMax(InpHistoryBars, InpAtrPeriod + InpAdxLength + InpAdxSmoothing + 10);
   int got = CopyRates(_Symbol, tf, 0, need, rates);
   return got >= InpAtrPeriod + 3;
  }

double TrueRange(const MqlRates &r[], const int i)
  {
   if(i == 0)
      return r[i].high - r[i].low;
   return MathMax(r[i].high - r[i].low,
                  MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
  }

// TradingView ta.rma: seeded with an SMA once `period` consecutive values exist.
void Rma(const double &src[], const int period, double &out[])
  {
   int n = ArraySize(src);
   ArrayResize(out, n);
   bool seeded = false;
   double prev = 0.0;
   int run = 0;
   for(int i = 0; i < n; i++)
     {
      bool valid = src[i] != EMPTY_VALUE;
      if(!seeded)
        {
         run = valid ? run + 1 : 0;
         if(run >= period)
           {
            double sum = 0.0;
            for(int k = i - period + 1; k <= i; k++)
               sum += src[k];
            prev = sum / period;
            seeded = true;
            out[i] = prev;
           }
         else
            out[i] = EMPTY_VALUE;
        }
      else
        {
         if(valid)
            prev = (prev * (period - 1) + src[i]) / period;
         out[i] = prev;
        }
     }
  }

// dir: -1 = uptrend, 1 = downtrend, 0 = not enough data (TradingView convention).
void CalcSupertrend(const MqlRates &r[], int &dir[], double &st[], double &atr[])
  {
   int n = ArraySize(r);
   ArrayResize(dir, n);
   ArrayResize(st, n);
   double tr[];
   ArrayResize(tr, n);
   for(int i = 0; i < n; i++)
      tr[i] = TrueRange(r, i);
   Rma(tr, InpAtrPeriod, atr);

   double upperPrev = 0.0, lowerPrev = 0.0, stPrev = 0.0;
   for(int i = 0; i < n; i++)
     {
      dir[i] = 0;
      st[i] = EMPTY_VALUE;
      if(atr[i] == EMPTY_VALUE)
         continue;
      double src = (r[i].high + r[i].low) / 2.0;
      double upper = src + InpFactor * atr[i];
      double lower = src - InpFactor * atr[i];
      double prevClose = i > 0 ? r[i - 1].close : r[i].close;
      lower = (lower > lowerPrev || prevClose < lowerPrev) ? lower : lowerPrev;
      upper = (upper < upperPrev || prevClose > upperPrev) ? upper : upperPrev;
      int d;
      if(i == 0 || atr[i - 1] == EMPTY_VALUE)
         d = 1;
      else if(stPrev == upperPrev)
         d = r[i].close > upper ? -1 : 1;
      else
         d = r[i].close < lower ? 1 : -1;
      st[i] = d == -1 ? lower : upper;
      dir[i] = d;
      upperPrev = upper;
      lowerPrev = lower;
      stPrev = st[i];
     }
  }

// TradingView ta.dmi(length, smoothing) -> ADX.
void CalcAdx(const MqlRates &r[], double &adx[])
  {
   int n = ArraySize(r);
   double tr[], plusDm[], minusDm[];
   ArrayResize(tr, n);
   ArrayResize(plusDm, n);
   ArrayResize(minusDm, n);
   for(int i = 0; i < n; i++)
     {
      tr[i] = TrueRange(r, i);
      if(i == 0)
        {
         plusDm[i] = EMPTY_VALUE;
         minusDm[i] = EMPTY_VALUE;
         continue;
        }
      double up = r[i].high - r[i - 1].high;
      double down = r[i - 1].low - r[i].low;
      plusDm[i] = (up > down && up > 0.0) ? up : 0.0;
      minusDm[i] = (down > up && down > 0.0) ? down : 0.0;
     }
   double trur[], plusS[], minusS[];
   Rma(tr, InpAdxLength, trur);
   Rma(plusDm, InpAdxLength, plusS);
   Rma(minusDm, InpAdxLength, minusS);

   double dx[];
   ArrayResize(dx, n);
   for(int i = 0; i < n; i++)
     {
      dx[i] = EMPTY_VALUE;
      if(trur[i] == EMPTY_VALUE || trur[i] == 0.0 || plusS[i] == EMPTY_VALUE || minusS[i] == EMPTY_VALUE)
         continue;
      double plus = 100.0 * plusS[i] / trur[i];
      double minus = 100.0 * minusS[i] / trur[i];
      double sum = plus + minus;
      dx[i] = MathAbs(plus - minus) / (sum != 0.0 ? sum : 1.0);
     }
   double smooth[];
   Rma(dx, InpAdxSmoothing, smooth);
   ArrayResize(adx, n);
   for(int i = 0; i < n; i++)
      adx[i] = smooth[i] == EMPTY_VALUE ? EMPTY_VALUE : 100.0 * smooth[i];
  }

// Supertrend direction of the last higher-timeframe candle that had CLOSED
// when the signal candle opened (same as the indicator: no repaint).
int HtfDirectionAt(const datetime barOpen)
  {
   MqlRates h[];
   if(!LoadRates(InpHtfFilterTf, h))
      return 0;
   int dir[];
   double st[], atr[];
   CalcSupertrend(h, dir, st, atr);
   int secs = PeriodSeconds(InpHtfFilterTf);
   for(int j = ArraySize(h) - 1; j >= 0; j--)
      if(h[j].time + secs <= barOpen)
         return dir[j];
   return 0;
  }

//+------------------------------------------------------------------+
//| Positions                                                        |
//+------------------------------------------------------------------+
bool IsOurPosition()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

// side: 1 = BUY, -1 = SELL
int CountPositions(const int side)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((side > 0 && type == POSITION_TYPE_BUY) || (side < 0 && type == POSITION_TYPE_SELL))
         count++;
     }
   return count;
  }

void CloseSide(const int side, const string why)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(!((side > 0 && type == POSITION_TYPE_BUY) || (side < 0 && type == POSITION_TYPE_SELL)))
         continue;
      if(g_trade.PositionClose(ticket))
         closed++;
      else
         Print("Close failed #", ticket, ": ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
     }
   if(closed > 0)
      Notify(StringFormat("🔁 ปิด %s %d ออเดอร์ %s %s (%s)", side > 0 ? "BUY" : "SELL", closed, _Symbol, TfName(SignalTf()), why));
  }

// Total volume from the lot mode, rounded down to the volume step. 0 = do not trade.
double TotalLots(const int side, const double entry, const double sl)
  {
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = minV;
   double lots = InpFixedLots;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double pl = 0.0;
      ENUM_ORDER_TYPE type = side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, pl) || pl == 0.0)
        {
         double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         pl = tickSize > 0.0 ? MathAbs(entry - sl) / tickSize * tickValue : 0.0;
        }
      double lossPerLot = MathAbs(pl);
      if(lossPerLot <= 0.0)
        {
         Notify("⚠ คำนวณมูลค่าความเสี่ยงต่อล็อตไม่ได้ ข้ามเทรดนี้");
         return 0.0;
        }
      lots = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0 / lossPerLot;
     }
   if(InpMaxTotalLots > 0.0)
      lots = MathMin(lots, InpMaxTotalLots);
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minV - 1e-9)
     {
      Notify(StringFormat("⚠ ล็อตที่คำนวณได้ %.4f ต่ำกว่าขั้นต่ำของโบรก %.2f ข้ามเทรดนี้", lots, minV));
      return 0.0;
     }
   return lots;
  }

// Split the total volume into the TP1/TP2/TP3 parts (whole volume steps,
// every non-empty part >= the broker minimum). Leftover steps go to TP1 first.
bool SplitVolume(const double total, double &vols[])
  {
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = minV;
   long units = (long)MathFloor(total / step + 1e-9);
   long minUnits = MathMax((long)1, (long)MathCeil(minV / step - 1e-9));

   double pct[3];
   pct[0] = MathMax(InpPart1Pct, 0.0);
   pct[1] = MathMax(InpPart2Pct, 0.0);
   pct[2] = MathMax(InpPart3Pct, 0.0);
   double pctSum = pct[0] + pct[1] + pct[2];
   if(pctSum <= 0.0)
     {
      pct[2] = 100.0;
      pctSum = 100.0;
     }

   long u[3];
   long used = 0;
   for(int k = 0; k < 3; k++)
     {
      u[k] = (long)MathFloor(units * pct[k] / pctSum);
      used += u[k];
     }
   for(long left = units - used; left > 0;)
      for(int k = 0; k < 3 && left > 0; k++)
         if(pct[k] > 0.0)
           {
            u[k]++;
            left--;
           }

   // Parts below the broker minimum are merged into the next part (or the previous one).
   for(int k = 0; k < 3; k++)
     {
      if(u[k] <= 0 || u[k] >= minUnits)
         continue;
      int target = -1;
      for(int m = k + 1; m < 3 && target < 0; m++)
         if(pct[m] > 0.0)
            target = m;
      for(int m = k - 1; m >= 0 && target < 0; m--)
         if(u[m] > 0)
            target = m;
      if(target < 0)
         return false;
      u[target] += u[k];
      u[k] = 0;
     }

   ArrayResize(vols, 3);
   bool any = false;
   for(int k = 0; k < 3; k++)
     {
      vols[k] = NormalizeDouble(MathMin(u[k] * step, maxV), 8);
      if(vols[k] > 0.0)
         any = true;
     }
   return any;
  }

// Market order; returns the position ticket (0 on failure).
ulong SendMarket(const int side, const double vol, const double sl, const double tp, const string comment)
  {
   bool ok = side > 0 ? g_trade.Buy(vol, _Symbol, 0.0, sl, tp, comment)
                      : g_trade.Sell(vol, _Symbol, 0.0, sl, tp, comment);
   uint rc = g_trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      Notify(StringFormat("❌ ส่งออเดอร์ %s %s ไม่สำเร็จ: %u %s", side > 0 ? "BUY" : "SELL", _Symbol, rc, g_trade.ResultRetcodeDescription()));
      return 0;
     }
   ulong deal = g_trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
     {
      long positionId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(positionId > 0)
         return (ulong)positionId;
     }
   if(g_netting && PositionSelect(_Symbol))
      return (ulong)PositionGetInteger(POSITION_TICKET);
   return g_trade.ResultOrder();
  }

bool OpenGroup(const int side, const double atrValue)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   double entry = side > 0 ? tick.ask : tick.bid;
   double risk = atrValue * InpSlAtrMult;
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(risk <= 0.0 || risk <= stopsLevel)
     {
      Notify(StringFormat("⚠ ระยะ SL %s ใกล้เกินกว่าที่โบรกอนุญาต (%s) ข้ามเทรดนี้", Fmt(risk), Fmt(stopsLevel)));
      return false;
     }
   double sl = NormPrice(entry - side * risk);
   double rr[3];
   rr[0] = InpTp1R;
   rr[1] = InpTp2R;
   rr[2] = InpTp3R;
   double tp[3];
   for(int k = 0; k < 3; k++)
      tp[k] = NormPrice(entry + side * risk * rr[k]);

   double total = TotalLots(side, entry, sl);
   if(total <= 0.0)
      return false;
   double vols[];
   if(!SplitVolume(total, vols))
     {
      Notify("⚠ แบ่งล็อตไม่ได้ (ล็อตรวมต่ำกว่าขั้นต่ำ) ข้ามเทรดนี้");
      return false;
     }
   string sideTxt = side > 0 ? "BUY" : "SELL";
   int opened = 0;

   if(g_netting)
     {
      // One position: TP = furthest used TP, the EA closes the TP1/TP2 parts.
      int last = -1;
      double sum = 0.0;
      for(int k = 0; k < 3; k++)
         if(vols[k] > 0.0)
           {
            last = k;
            sum += vols[k];
           }
      ulong ticket = SendMarket(side, NormalizeDouble(sum, 8), sl, tp[last], "ST67 " + sideTxt);
      if(ticket > 0)
        {
         string key = GvPositionKey(ticket);
         GlobalVariableSet(key + "_R", risk);
         GlobalVariableSet(key + "_V1", last > 0 ? vols[0] : 0.0);
         GlobalVariableSet(key + "_V2", last > 1 ? vols[1] : 0.0);
         GlobalVariableSet(key + "_S", 0.0);
         opened = 1;
        }
     }
   else
     {
      for(int k = 0; k < 3; k++)
        {
         if(vols[k] <= 0.0)
            continue;
         ulong ticket = SendMarket(side, vols[k], sl, tp[k], StringFormat("ST67 %s TP%d", sideTxt, k + 1));
         if(ticket > 0)
           {
            GlobalVariableSet(GvPositionKey(ticket) + "_R", risk);
            opened++;
           }
        }
     }
   if(opened == 0)
      return false;

   string msg = StringFormat("%s %s %s %s\nEntry ~%s\nSL %s (risk %s)",
                             side > 0 ? "🟢" : "🔴", sideTxt, _Symbol, TfName(SignalTf()),
                             Fmt(entry), Fmt(sl), Fmt(risk));
   for(int k = 0; k < 3; k++)
      if(vols[k] > 0.0)
         msg += StringFormat("\nTP%d %s (%.2f lot)", k + 1, Fmt(tp[k]), vols[k]);
   Notify(msg);
   return true;
  }

//+------------------------------------------------------------------+
//| Move SL (break-even, SL to TP1) and netting partial closes       |
//+------------------------------------------------------------------+
void TryMoveSl(const ulong ticket, const bool isBuy, const double curSl, const double tp, double newSl, const string why)
  {
   newSl = NormPrice(newSl);
   bool better = isBuy ? (curSl == 0.0 || newSl > curSl + _Point / 2.0)
                       : (curSl == 0.0 || newSl < curSl - _Point / 2.0);
   if(!better || TimeCurrent() < g_modifyBlockedUntil)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(isBuy ? tick.bid - newSl <= minDist : newSl - tick.ask <= minDist)
      return;   // too close to the price right now, try again on a later tick
   if(g_trade.PositionModify(ticket, newSl, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      Notify(StringFormat("🛡 #%I64u %s: SL → %s", ticket, why, Fmt(newSl)), false);
   else
     {
      Print("Modify failed #", ticket, ": ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      g_modifyBlockedUntil = TimeCurrent() + 10;
     }
  }

void ManagePositions()
  {
   if(!g_netting && !InpBeAfterTp1 && !InpSlToTp1AfterTp2)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      string key = GvPositionKey(ticket);
      if(!GlobalVariableCheck(key + "_R"))
         continue;
      double risk = GlobalVariableGet(key + "_R");
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double sign = isBuy ? 1.0 : -1.0;
      double price = isBuy ? tick.bid : tick.ask;
      double tp1 = open + sign * risk * InpTp1R;
      double tp2 = open + sign * risk * InpTp2R;
      bool passTp1 = isBuy ? price >= tp1 : price <= tp1;
      bool passTp2 = isBuy ? price >= tp2 : price <= tp2;

      if(g_netting && TimeCurrent() >= g_modifyBlockedUntil)
        {
         double stage = GvGet(key + "_S", 0.0);
         if(stage < 1.0 && passTp1)
           {
            double v1 = GvGet(key + "_V1", 0.0);
            if(v1 <= 0.0 || v1 >= vol)
               GlobalVariableSet(key + "_S", 1.0);
            else if(g_trade.PositionClosePartial(ticket, v1))
              {
               GlobalVariableSet(key + "_S", 1.0);
               vol -= v1;
               Notify(StringFormat("✅ TP1 %s %s ปิดบางส่วน %.2f lot ที่ ~%s", isBuy ? "BUY" : "SELL", _Symbol, v1, Fmt(price)));
              }
            else
               g_modifyBlockedUntil = TimeCurrent() + 10;
            stage = GvGet(key + "_S", 0.0);
           }
         if(stage >= 1.0 && stage < 2.0 && passTp2)
           {
            double v2 = GvGet(key + "_V2", 0.0);
            if(v2 <= 0.0 || v2 >= vol)
               GlobalVariableSet(key + "_S", 2.0);
            else if(g_trade.PositionClosePartial(ticket, v2))
              {
               GlobalVariableSet(key + "_S", 2.0);
               Notify(StringFormat("✅ TP2 %s %s ปิดบางส่วน %.2f lot ที่ ~%s", isBuy ? "BUY" : "SELL", _Symbol, v2, Fmt(price)));
              }
            else
               g_modifyBlockedUntil = TimeCurrent() + 10;
           }
        }

      if(InpSlToTp1AfterTp2 && passTp2)
         TryMoveSl(ticket, isBuy, sl, tp, tp1, "ถึง TP2 เลื่อน SL ไป TP1");
      else if(InpBeAfterTp1 && passTp1)
         TryMoveSl(ticket, isBuy, sl, tp, open + sign * InpBeOffsetPts * _Point, "ถึง TP1 กันทุน");
     }
  }

// Remove stored levels of positions that are no longer open.
void SweepGlobals()
  {
   string prefix = GvPrefix() + "P";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0)
         continue;
      string rest = StringSubstr(name, StringLen(prefix));
      int sep = StringFind(rest, "_");
      if(sep <= 0)
         continue;
      ulong ticket = (ulong)StringToInteger(StringSubstr(rest, 0, sep));
      if(!PositionSelectByTicket(ticket))
         GlobalVariableDel(name);
     }
  }

//+------------------------------------------------------------------+
//| Signal on the candle that just closed                            |
//+------------------------------------------------------------------+
// Returns false when the data is not ready yet (retry on the next tick).
bool EvaluateClosedBar(const datetime currentBarOpen)
  {
   MqlRates r[];
   if(!LoadRates(SignalTf(), r))
      return false;
   int n = ArraySize(r);
   if(n < 3 || r[n - 1].time != currentBarOpen)
      return false;

   int dir[];
   double st[], atr[], adx[];
   CalcSupertrend(r, dir, st, atr);
   CalcAdx(r, adx);
   int s = n - 2;   // the candle that just closed
   g_lastDir = dir[s];
   g_lastSt = st[s];
   g_lastAdx = adx[s];
   bool htfOn = HtfFilterOn();
   if(htfOn)
      g_lastHtfDir = HtfDirectionAt(r[s].time);

   if(dir[s] == 0 || dir[s - 1] == 0)
      return true;
   int flip = 0;
   if(dir[s] < 0 && dir[s - 1] > 0)
      flip = 1;    // BUY
   else if(dir[s] > 0 && dir[s - 1] < 0)
      flip = -1;   // SELL
   if(flip == 0)
      return true;

   // Never act twice on the same candle (also after a terminal restart).
   string lastKey = GvLastSignalKey();
   if(GlobalVariableCheck(lastKey) && (datetime)GlobalVariableGet(lastKey) >= r[s].time)
      return true;
   GlobalVariableSet(lastKey, (double)r[s].time);

   string sideTxt = flip > 0 ? "BUY" : "SELL";
   long elapsed = (long)(TimeCurrent() - r[n - 1].time);
   if(elapsed > (long)PeriodSeconds(SignalTf()) * InpMaxDelayPct / 100)
     {
      Notify(StringFormat("⏭ สัญญาณ %s %s %s ผ่านมานานแล้ว (EA เพิ่งเริ่ม) ไม่เข้า", sideTxt, _Symbol, TfName(SignalTf())), false);
      return true;
     }

   string blocked = "";
   if(flip > 0 && !InpAllowBuy)
      blocked += "ปิดฝั่ง BUY ไว้; ";
   if(flip < 0 && !InpAllowSell)
      blocked += "ปิดฝั่ง SELL ไว้; ";
   if(InpUseAdxFilter && (adx[s] == EMPTY_VALUE || adx[s] <= InpAdxMin))
      blocked += StringFormat("ADX %.1f ไม่เกิน %.1f; ", adx[s] == EMPTY_VALUE ? 0.0 : adx[s], InpAdxMin);
   if(htfOn && !((flip > 0 && g_lastHtfDir < 0) || (flip < 0 && g_lastHtfDir > 0)))
      blocked += "เทรนด์ " + TfName(InpHtfFilterTf) + " เป็น" + DirText(g_lastHtfDir) + "; ";
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts)
      blocked += StringFormat("สเปรด %d > %d points; ", (int)spread, InpMaxSpreadPts);

   bool passed = blocked == "";
   if(InpOppositeMode == OPPOSITE_ON_FLIP || (InpOppositeMode == OPPOSITE_ON_SIGNAL && passed))
      if(CountPositions(-flip) > 0)
         CloseSide(-flip, "สัญญาณกลับทิศ");

   if(!passed)
     {
      Notify(StringFormat("⏸ สัญญาณ %s %s %s ไม่เข้า: %s", sideTxt, _Symbol, TfName(SignalTf()), blocked));
      return true;
     }
   if(CountPositions(flip) > 0)
     {
      Notify(StringFormat("ℹ สัญญาณ %s %s แต่ยังมีออเดอร์ฝั่งเดียวกันเปิดอยู่ ไม่เปิดซ้อน", sideTxt, _Symbol), false);
      return true;
     }
   OpenGroup(flip, atr[s]);
   return true;
  }

void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   string s = "ST TP/SL EA · " + _Symbol + " " + TfName(SignalTf()) + "\n";
   s += "เทรนด์ (แท่งปิดล่าสุด): " + DirText(g_lastDir) + "   เส้น ST " + (g_lastSt == EMPTY_VALUE ? "-" : Fmt(g_lastSt)) + "\n";
   s += "ADX: " + (g_lastAdx == EMPTY_VALUE ? "-" : DoubleToString(g_lastAdx, 1));
   s += InpUseAdxFilter ? StringFormat(" (ต้อง > %.1f)\n", InpAdxMin) : " (ไม่กรอง)\n";
   if(HtfFilterOn())
      s += "เทรนด์ " + TfName(InpHtfFilterTf) + ": " + DirText(g_lastHtfDir) + "\n";
   s += StringFormat("ออเดอร์ของ EA: BUY %d · SELL %d\n", CountPositions(1), CountPositions(-1));
   s += g_netting ? "บัญชี Netting: 1 ออเดอร์ EA ปิดบางส่วนที่ TP1/TP2\n" : "บัญชี Hedging: แยกออเดอร์ตาม TP1/TP2/TP3\n";
   s += "ล่าสุด: " + g_lastEvent;
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFactor <= 0.0 || InpAtrPeriod < 1 || InpSlAtrMult <= 0.0 || InpTp1R <= 0.0 || InpTp2R <= 0.0 || InpTp3R <= 0.0
      || InpAdxLength < 1 || InpAdxSmoothing < 1 || InpHistoryBars < 50)
     {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_netting = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   if(InpHtfFilterTf != PERIOD_CURRENT && !HtfFilterOn())
      Print("HTF filter ignored: ", TfName(InpHtfFilterTf), " is not larger than ", TfName(SignalTf()));
   g_lastBarTime = 0;
   UpdatePanel();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
  }

void OnTick()
  {
   ManagePositions();
   datetime barOpen = iTime(_Symbol, SignalTf(), 0);
   if(barOpen != 0 && barOpen != g_lastBarTime && EvaluateClosedBar(barOpen))
     {
      g_lastBarTime = barOpen;
      SweepGlobals();
     }
   UpdatePanel();
  }

// Report SL / TP / stop-out closes done by the broker.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic || HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string what;
   if(reason == DEAL_REASON_TP)
      what = "✅ ถึง TP";
   else if(reason == DEAL_REASON_SL)
      what = "🛑 โดน SL";
   else if(reason == DEAL_REASON_SO)
      what = "⚠ Stop out";
   else
      return;   // closes made by this EA are reported where they happen
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                   + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   Notify(StringFormat("%s %s %.2f lot ที่ %s กำไร/ขาดทุน %.2f %s", what, _Symbol,
                       HistoryDealGetDouble(trans.deal, DEAL_VOLUME), Fmt(HistoryDealGetDouble(trans.deal, DEAL_PRICE)),
                       profit, AccountInfoString(ACCOUNT_CURRENCY)));
  }
//+------------------------------------------------------------------+
