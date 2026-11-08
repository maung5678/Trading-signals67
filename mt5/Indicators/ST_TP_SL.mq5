//+------------------------------------------------------------------+
//|                                                     ST_TP_SL.mq5 |
//|  MT5 port of indicators/ST_with_TP_SL.pine (TradingView).        |
//|                                                                  |
//|  - Supertrend line, BUY/SELL on closed candles (no repaint)      |
//|  - Entry / SL / TP1-TP3 lines, zones, price labels, TP marks     |
//|  - Optional filters: ADX, higher-timeframe trend, EMA 200        |
//|  - Optional signals: trend-line/channel breakout, re-entry       |
//|    after TP3 (Supertrend touch, EMA cross, fast EMA touch)       |
//|  - Dashboards: statistics, win rate per timeframe, ADX,          |
//|    multi-timeframe trend, trade history                          |
//|                                                                  |
//|  One signal engine (class CEngine) is used for the chart and for |
//|  the win-rate-per-timeframe table, so both count the same way.   |
//|                                                                  |
//|  The EA (Experts/ST_TP_SL_EA.mq5) embeds this indicator and      |
//|  trades its signal buffers. Buffers read by the EA:              |
//|   3 Supertrend value   13 signal (1 BUY, -1 SELL, 0)             |
//|  14 entry  15 SL  16 TP1  17 TP2  18 TP3                         |
//|  19 direction (-1 up, 1 down)  20 ATR  21 ADX                    |
//|  Keep the input order in sync with the EA:                       |
//|  python3 mt5/tools/check_inputs.py                               |
//+------------------------------------------------------------------+
#property copyright   "Trading-signals67"
#property link        "https://github.com/maung5678/Trading-signals67"
#property version     "1.11"
#property description "Supertrend TP/SL v1.11: สัญญาณ BUY/SELL บนแท่งที่ปิดแล้ว พร้อม Entry, SL, TP1–TP3 และแดชบอร์ด"
#property indicator_chart_window
#property indicator_buffers 22
#property indicator_plots   17

#property indicator_label1  "Supertrend ขาขึ้น"
#property indicator_type1   DRAW_LINE
#property indicator_color1  C'8,153,129'
#property indicator_width1  2
#property indicator_label2  "Supertrend ขาลง"
#property indicator_type2   DRAW_LINE
#property indicator_color2  C'242,54,69'
#property indicator_width2  2
#property indicator_label3  "ราคาปิด;Supertrend"
#property indicator_type3   DRAW_FILLING
#property indicator_color3  C'8,153,129',C'242,54,69'
#property indicator_label4  "แท่งเทียน O;H;L;C"
#property indicator_type4   DRAW_COLOR_CANDLES
#property indicator_color4  clrLime,clrRed
#property indicator_label5  "BUY"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  C'8,153,129'
#property indicator_width5  2
#property indicator_label6  "SELL"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  C'242,54,69'
#property indicator_width6  2
#property indicator_label7  "EMA 200"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrSilver
#property indicator_width7  2
#property indicator_label8  "EMA เข้าซ้ำ"
#property indicator_type8   DRAW_LINE
#property indicator_color8  C'91,156,246'
#property indicator_width8  1
#property indicator_label9  "Signal (1=BUY, -1=SELL)"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "Entry"
#property indicator_type10  DRAW_NONE
#property indicator_label11 "SL"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "TP1"
#property indicator_type12  DRAW_NONE
#property indicator_label13 "TP2"
#property indicator_type13  DRAW_NONE
#property indicator_label14 "TP3"
#property indicator_type14  DRAW_NONE
#property indicator_label15 "Direction (-1=ขึ้น, 1=ลง)"
#property indicator_type15  DRAW_NONE
#property indicator_label16 "ATR"
#property indicator_type16  DRAW_NONE
#property indicator_label17 "ADX"
#property indicator_type17  DRAW_NONE

#define IND_VERSION "1.11"

enum ENUM_DASH_MODE
  {
   DASH_FULL = 0,     // เต็ม
   DASH_COMPACT = 1,  // ย่อ
   DASH_HIDDEN = 2    // ซ่อน
  };

enum ENUM_STATS_PERIOD
  {
   STATS_1H = 0,   // 1 ชั่วโมงล่าสุด
   STATS_4H = 1,   // 4 ชั่วโมงล่าสุด
   STATS_1D = 2,   // 1 วันล่าสุด
   STATS_1W = 3,   // 1 สัปดาห์ล่าสุด
   STATS_1M = 4,   // 1 เดือนล่าสุด (30 วัน)
   STATS_ALL = 5   // ทั้งหมดที่คำนวณ
  };

enum ENUM_LOG_LEVEL
  {
   LOG_ERRORS = 0, // เฉพาะข้อผิดพลาด
   LOG_NORMAL = 1, // ปกติ
   LOG_DETAIL = 2  // ละเอียด (ใช้ตอนทดสอบ / ส่งให้ตรวจ)
  };

//--- Inputs. Order matters: the EA passes them by position (colors last, not passed).
input group "สัญญาณ"
input double            InpFactor            = 2.5;   // Factor (ตัวคูณ Supertrend)
input int               InpAtrPeriod         = 14;    // ATR (จำนวนแท่ง)
input group "จุด SL / TP"
input double            InpSlAtrMult         = 1.5;   // SL = ATR ×
input double            InpTp1R              = 1.0;   // TP1 (R)
input double            InpTp2R              = 2.0;   // TP2 (R)
input double            InpTp3R              = 3.0;   // TP3 (R)
input group "การแสดงผลบนกราฟ"
input bool              InpShowSignals       = true;  // แสดงป้าย BUY / SELL
input bool              InpShowTrendLine     = true;  // แสดงเส้น Supertrend
input bool              InpShowFill          = true;  // ระบายสีพื้นที่เทรนด์
input bool              InpShowCandleColors  = true;  // ระบายสีแท่งเทียนตามเทรนด์
input bool              InpShowLevels        = true;  // แสดงเส้น Entry, TP1–TP3, SL
input bool              InpShowBoxes         = true;  // แสดงโซนกำไร / ขาดทุน
input bool              InpShowTpMarks       = true;  // ติดป้าย ✓ เมื่อถึง TP / ✗ เมื่อโดน SL
input bool              InpShowPriceLabels   = true;  // แสดงป้ายราคา
input int               InpPriceLabelOffset  = 15;    // ระยะป้ายราคา (แท่ง)
input int               InpMaxBars           = 5000;  // จำนวนแท่งย้อนหลังที่คำนวณ
input int               InpObjectBars        = 1500;  // วาดป้ายย้อนหลังกี่แท่ง
input group "แดชบอร์ด"
input bool              InpHideAllDashboards = false;              // ซ่อนแดชบอร์ดทั้งหมด
input ENUM_DASH_MODE    InpStatsMode         = DASH_COMPACT;       // สถิติชนะ/แพ้ (TF ของกราฟ)
input ENUM_STATS_PERIOD InpStatsPeriod       = STATS_ALL;          // ช่วงเวลาของสถิติ
input ENUM_BASE_CORNER  InpStatsCorner       = CORNER_RIGHT_UPPER; // ตำแหน่งสถิติ
input ENUM_DASH_MODE    InpTfStatsMode       = DASH_FULL;          // ตารางเทียบอัตราชนะหลาย TF
input int               InpTfStatsDays       = 30;                 // ตารางเทียบ: นับย้อนหลังกี่วัน
input ENUM_BASE_CORNER  InpTfStatsCorner     = CORNER_LEFT_LOWER;  // ตำแหน่งตารางเทียบ
input ENUM_DASH_MODE    InpAdxMode           = DASH_COMPACT;       // แดชบอร์ด ADX
input ENUM_BASE_CORNER  InpAdxCorner         = CORNER_RIGHT_UPPER; // ตำแหน่ง ADX
input ENUM_DASH_MODE    InpMtfMode           = DASH_COMPACT;       // เทรนด์หลายไทม์เฟรม
input ENUM_BASE_CORNER  InpMtfCorner         = CORNER_RIGHT_LOWER; // ตำแหน่งเทรนด์หลายไทม์เฟรม
input ENUM_DASH_MODE    InpHistoryMode       = DASH_HIDDEN;        // ประวัติเทรด
input ENUM_BASE_CORNER  InpHistoryCorner     = CORNER_LEFT_LOWER;  // ตำแหน่งประวัติเทรด
input int               InpDashFontSize      = 8;                  // ขนาดตัวอักษรแดชบอร์ด
input group "การแจ้งเตือน (ใช้อินดิเคเตอร์เดี่ยว ๆ ไม่มี EA)"
input bool              InpAlertOnSignal     = false; // แจ้งเมื่อมีสัญญาณ BUY/SELL
input bool              InpAlertOnTpSl       = false; // แจ้งเมื่อถึง TP / โดน SL
input bool              InpAlertPopup        = true;  // แจ้งแบบ popup บนคอม
input bool              InpAlertPush         = false; // ส่งเข้าแอป MT5 มือถือ
input group "ตัวเลือกเสริม: ตัวกรองสัญญาณ (ค่าเริ่มต้นปิด)"
input bool              InpUseAdxFilter      = false;          // สัญญาณเฉพาะตอน ADX แรง
input double            InpAdxSignalMin      = 25.0;           // เกณฑ์ ADX ของสัญญาณ (ต้องสูงกว่า)
input ENUM_TIMEFRAMES   InpHtfFilterTf       = PERIOD_CURRENT; // กรองด้วยเทรนด์ TF ใหญ่ (CURRENT = ไม่ใช้)
input bool              InpUseEma200Filter   = false;          // กรองด้วย EMA 200
input group "ตัวเลือกเสริม: สัญญาณเพิ่ม (ค่าเริ่มต้นปิด)"
input bool              InpBreakoutSignals   = false; // สัญญาณเบรกเทรนด์ไลน์ / กรอบ
input bool              InpReentrySt         = false; // เข้าซ้ำหลัง TP3 (ย่อมาแตะ Supertrend)
input bool              InpReentryEma        = false; // เข้าซ้ำหลัง TP3 (ตัด EMA)
input bool              InpReentryEmaFast    = false; // เข้าซ้ำหลัง TP3 (แตะ EMA แบบเร็ว)
input int               InpReentryEmaLength  = 13;    // EMA สำหรับเข้าซ้ำ (13, 9 หรือ 5)
input group "ตัวเลือกเสริม: เส้นบนกราฟ (ค่าเริ่มต้นปิด)"
input bool              InpShowKeyLevels     = false; // แสดงแนวรับ / แนวต้านแนวนอน
input bool              InpShowTrendlines    = false; // แสดงเส้นเทรนด์ไลน์ทแยง
input bool              InpShowChannel       = false; // แสดงกรอบราคา (Channel)
input bool              InpOnlyCurrentSlope  = true;  // เฉพาะเส้นที่ตรงกับเทรนด์
input int               InpPivotLength       = 5;     // ความยาว Pivot (แท่งซ้าย/ขวา)
input int               InpKeyLevelsCount    = 3;     // จำนวนแนวรับ/แนวต้านต่อฝั่ง
input double            InpKeyLevelTolAtr    = 0.5;   // ระยะรวมแนว (× ATR)
input group "ค่าคำนวณ ADX / หลายไทม์เฟรม"
input int               InpAdxLength         = 14;    // ADX: ความยาว DI
input int               InpAdxSmoothing      = 14;    // ADX: การปรับเรียบ
input double            InpAdxRangeLevel     = 20.0;  // ADX ต่ำกว่านี้ = ไซด์เวย์
input double            InpAdxStrongLevel    = 25.0;  // ADX ตั้งแต่นี้ = เทรนด์แรง
input double            InpNeutralZone       = 10.0;  // โซนกลาง ± (หลายไทม์เฟรม)
input group "ระบบ"
input bool              InpDrawObjects       = true;        // วาดป้าย เส้น และแดชบอร์ดบนกราฟ (EA ปิดในตัวที่ใช้เทรด)
input ENUM_LOG_LEVEL    InpLogLevel          = LOG_NORMAL;  // ระดับ log (แท็บ Experts)
input group "สี"
input color             InpUpColor           = C'8,153,129';   // ขาขึ้น
input color             InpDownColor         = C'242,54,69';   // ขาลง
input color             InpEntryColor        = C'91,156,246';  // Entry
input color             InpTp1Color          = C'38,166,154';  // TP1
input color             InpTp2Color          = C'8,153,129';   // TP2
input color             InpTp3Color          = C'0,105,92';    // TP3
input color             InpSlColor           = C'242,54,69';   // SL
input color             InpCandleUpColor     = clrLime;        // แท่งเทียนขาขึ้น
input color             InpCandleDownColor   = clrRed;         // แท่งเทียนขาลง
input color             InpSupportColor      = C'8,153,129';   // เส้นแนวรับ
input color             InpResistanceColor   = C'242,54,69';   // เส้นแนวต้าน
input color             InpChannelColor      = C'91,156,246';  // กรอบราคา

//--- Plot buffers (EA reads 3 and 13..21)
double B_stUp[], B_stDn[], B_fillClose[], B_st[];
double B_cO[], B_cH[], B_cL[], B_cC[], B_cClr[];
double B_buy[], B_sell[], B_ema200[], B_emaRe[];
double B_sig[], B_entry[], B_sl[], B_tp1[], B_tp2[], B_tp3[], B_dir[], B_atr[], B_adx[];

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
string g_logTag = "[ST67][IND]";
string g_onceKeys[];

void Log(const ENUM_LOG_LEVEL level, const string msg)
  {
   if(level <= InpLogLevel)
      Print(g_logTag, " ", msg);
  }

// Log a message only the first time `key` is seen (avoids flooding the journal).
void LogOnce(const ENUM_LOG_LEVEL level, const string key, const string msg)
  {
   int n = ArraySize(g_onceKeys);
   for(int i = 0; i < n; i++)
      if(g_onceKeys[i] == key)
         return;
   if(n < 500)
     {
      ArrayResize(g_onceKeys, n + 1);
      g_onceKeys[n] = key;
     }
   Log(level, msg);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
color Blend(const color a, const color b, const double weightA)
  {
   int ai = (int)a, bi = (int)b;
   int r = (int)((ai & 0xFF) * weightA + (bi & 0xFF) * (1.0 - weightA));
   int g = (int)(((ai >> 8) & 0xFF) * weightA + ((bi >> 8) & 0xFF) * (1.0 - weightA));
   int bl = (int)(((ai >> 16) & 0xFF) * weightA + ((bi >> 16) & 0xFF) * (1.0 - weightA));
   return (color)(r | (g << 8) | (bl << 16));
  }

color ChartBg() { return (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND); }
color ChartFg() { return (color)ChartGetInteger(0, CHART_COLOR_FOREGROUND); }
string Fmt(const double price) { return DoubleToString(price, _Digits); }

string TfName(const ENUM_TIMEFRAMES tf)
  {
   ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   return StringSubstr(EnumToString(t), 7);
  }

void Notify(const string msg)
  {
   Log(LOG_NORMAL, msg);
   if(InpAlertPopup)
      Alert(msg);
   if(InpAlertPush && !MQLInfoInteger(MQL_TESTER))
      SendNotification(StringSubstr(msg, 0, 255));
  }

//+------------------------------------------------------------------+
//| Indicator math on MqlRates arrays (index 0 = oldest).            |
//| Used for the higher-timeframe filter and the MTF trend table.    |
//| Same formulas as TradingView ta.rma / ta.supertrend / ta.dmi.    |
//+------------------------------------------------------------------+
double RatesTr(const MqlRates &r[], const int i)
  {
   if(i == 0)
      return r[i].high - r[i].low;
   return MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
  }

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

void RatesSupertrend(const MqlRates &r[], int &dir[])
  {
   int n = ArraySize(r);
   ArrayResize(dir, n);
   double tr[], atr[];
   ArrayResize(tr, n);
   for(int i = 0; i < n; i++)
      tr[i] = RatesTr(r, i);
   Rma(tr, InpAtrPeriod, atr);
   double upperPrev = 0.0, lowerPrev = 0.0, stPrev = 0.0;
   for(int i = 0; i < n; i++)
     {
      dir[i] = 0;
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
      else
         if(stPrev == upperPrev)
            d = r[i].close > upper ? -1 : 1;
         else
            d = r[i].close < lower ? 1 : -1;
      double st = d == -1 ? lower : upper;
      dir[i] = d;
      upperPrev = upper;
      lowerPrev = lower;
      stPrev = st;
     }
  }

double RatesAdxLast(const MqlRates &r[])
  {
   int n = ArraySize(r);
   double tr[], pdm[], mdm[];
   ArrayResize(tr, n);
   ArrayResize(pdm, n);
   ArrayResize(mdm, n);
   for(int i = 0; i < n; i++)
     {
      tr[i] = RatesTr(r, i);
      if(i == 0)
        {
         pdm[i] = EMPTY_VALUE;
         mdm[i] = EMPTY_VALUE;
         continue;
        }
      double up = r[i].high - r[i - 1].high;
      double down = r[i - 1].low - r[i].low;
      pdm[i] = (up > down && up > 0.0) ? up : 0.0;
      mdm[i] = (down > up && down > 0.0) ? down : 0.0;
     }
   double trur[], ps[], ms[], dx[], sm[];
   Rma(tr, InpAdxLength, trur);
   Rma(pdm, InpAdxLength, ps);
   Rma(mdm, InpAdxLength, ms);
   ArrayResize(dx, n);
   for(int i = 0; i < n; i++)
     {
      dx[i] = EMPTY_VALUE;
      if(trur[i] == EMPTY_VALUE || trur[i] == 0.0 || ps[i] == EMPTY_VALUE || ms[i] == EMPTY_VALUE)
         continue;
      double p = 100.0 * ps[i] / trur[i], m = 100.0 * ms[i] / trur[i];
      double s = p + m;
      dx[i] = MathAbs(p - m) / (s != 0.0 ? s : 1.0);
     }
   Rma(dx, InpAdxSmoothing, sm);
   return (n == 0 || sm[n - 1] == EMPTY_VALUE) ? EMPTY_VALUE : 100.0 * sm[n - 1];
  }

//+------------------------------------------------------------------+
//| Signal engine: indicator values, signals and the virtual trade   |
//| (same model as the TradingView statistics). Arrays: index 0 =    |
//| oldest bar. Used for the chart and for each row of the win-rate  |
//| per timeframe table.                                             |
//+------------------------------------------------------------------+
struct TradeRec
  {
   datetime          time;       // signal candle open time
   int               side;       // 1 = BUY, -1 = SELL
   bool              resolved;   // win/loss known
   bool              win;
   double            statR;      // R for the statistics (TP1 = win, SL = -1, reversal = real R)
   bool              histDone;   // outcome for the history table recorded
   string            outcome;    // TP1 / TP2 / TP3 / TP2→SL / SL / REV
   double            histR;
   bool              slHit;
  };

// What happened on one closed candle (used for drawing and alerts).
struct BarEvents
  {
   bool              buy;
   bool              sell;
   bool              tpHit[3];
   double            tpPrice[3];
   bool              slHit;
   double            slPrice;
  };

void ClearEvents(BarEvents &ev)
  {
   ev.buy = false;
   ev.sell = false;
   for(int k = 0; k < 3; k++)
     {
      ev.tpHit[k] = false;
      ev.tpPrice[k] = 0.0;
     }
   ev.slHit = false;
   ev.slPrice = 0.0;
  }

class CEngine
  {
public:
   ENUM_TIMEFRAMES   tf;
   int               first;        // first calculated bar
   int               lastClosed;   // last closed bar run through Closed()
   bool              htfOn;
   datetime          htfTime[];
   int               htfDir[];
   //--- series
   double            atr[], upper[], lower[], st[], dir[], trur[], ps[], ms[], dx[], adxRaw[], adx[], ema200[], emaRe[];
   //--- virtual trade
   int               tDir;
   double            entry, sl, tp1, tp2, tp3;
   int               tradeBar;
   bool              tp1Reached, tp2Reached, tp3Reached, resolved, histRecorded;
   bool              reLongArmed, reShortArmed, emaLongPull, emaShortPull;
   //--- pivots (bar indexes, -1 = none)
   double            prevSupP, lastSupP, prevResP, lastResP;
   int               prevSupB, lastSupB, prevResB, lastResB;
   double            kSupPrice[], kResPrice[];
   int               kSupBar[], kResBar[];
   //--- records
   TradeRec          recs[];
   int               recCount;

   void              Init(const ENUM_TIMEFRAMES timeframe)
     {
      tf = timeframe;
      htfOn = InpHtfFilterTf != PERIOD_CURRENT && PeriodSeconds(InpHtfFilterTf) > PeriodSeconds(timeframe);
     }

   void              Resize(const int total)
     {
      ArrayResize(atr, total, 1000);
      ArrayResize(upper, total, 1000);
      ArrayResize(lower, total, 1000);
      ArrayResize(st, total, 1000);
      ArrayResize(dir, total, 1000);
      ArrayResize(trur, total, 1000);
      ArrayResize(ps, total, 1000);
      ArrayResize(ms, total, 1000);
      ArrayResize(dx, total, 1000);
      ArrayResize(adxRaw, total, 1000);
      ArrayResize(adx, total, 1000);
      ArrayResize(ema200, total, 1000);
      ArrayResize(emaRe, total, 1000);
     }

   void              Reset(const int total, const int firstBar)
     {
      Resize(total);
      first = firstBar;
      lastClosed = firstBar;   // the first bar has no previous bar for a signal
      tDir = 0;
      entry = EMPTY_VALUE;
      sl = EMPTY_VALUE;
      tp1 = EMPTY_VALUE;
      tp2 = EMPTY_VALUE;
      tp3 = EMPTY_VALUE;
      tradeBar = -1;
      tp1Reached = false;
      tp2Reached = false;
      tp3Reached = false;
      resolved = false;
      histRecorded = false;
      reLongArmed = false;
      reShortArmed = false;
      emaLongPull = false;
      emaShortPull = false;
      prevSupP = EMPTY_VALUE;
      lastSupP = EMPTY_VALUE;
      prevResP = EMPTY_VALUE;
      lastResP = EMPTY_VALUE;
      prevSupB = -1;
      lastSupB = -1;
      prevResB = -1;
      lastResB = -1;
      ArrayResize(kSupPrice, 0);
      ArrayResize(kResPrice, 0);
      ArrayResize(kSupBar, 0);
      ArrayResize(kResBar, 0);
      ArrayResize(recs, 0);
      recCount = 0;
      for(int i = 0; i < firstBar && i < total; i++)
        {
         atr[i] = EMPTY_VALUE;
         upper[i] = EMPTY_VALUE;
         lower[i] = EMPTY_VALUE;
         st[i] = EMPTY_VALUE;
         dir[i] = 0.0;
         trur[i] = EMPTY_VALUE;
         ps[i] = EMPTY_VALUE;
         ms[i] = EMPTY_VALUE;
         dx[i] = EMPTY_VALUE;
         adxRaw[i] = EMPTY_VALUE;
         adx[i] = EMPTY_VALUE;
         ema200[i] = EMPTY_VALUE;
         emaRe[i] = EMPTY_VALUE;
        }
     }

   //--- Higher-timeframe direction of the last HTF candle closed when `barOpen` started (no repaint).
   bool              LoadHtf(const datetime fromTime)
     {
      MqlRates h[];
      int secs = PeriodSeconds(InpHtfFilterTf);
      datetime from = (datetime)((long)fromTime - (long)secs * (InpAtrPeriod * 20 + 50));
      datetime to = (datetime)((long)TimeCurrent() + secs);
      int got = CopyRates(_Symbol, InpHtfFilterTf, from, to, h);
      if(got < InpAtrPeriod + 3)
        {
         Log(LOG_NORMAL, StringFormat("ข้อมูล TF ใหญ่ %s ยังไม่พร้อม (ได้ %d แท่ง, error %d) จะลองใหม่", TfName(InpHtfFilterTf), got, GetLastError()));
         return false;
        }
      int d[];
      RatesSupertrend(h, d);
      ArrayResize(htfTime, got);
      ArrayResize(htfDir, got);
      for(int j = 0; j < got; j++)
        {
         htfTime[j] = h[j].time;
         htfDir[j] = d[j];
        }
      return true;
     }

   int               HtfDirAt(const datetime barOpen)
     {
      int n = ArraySize(htfTime);
      int secs = PeriodSeconds(InpHtfFilterTf);
      int lo = 0, hi = n - 1, found = -1;
      while(lo <= hi)
        {
         int mid = (lo + hi) / 2;
         if((long)htfTime[mid] + secs <= (long)barOpen)
           {
            found = mid;
            lo = mid + 1;
           }
         else
            hi = mid - 1;
        }
      return found < 0 ? 0 : htfDir[found];
     }

   double            TrAt(const int i, const double &h[], const double &l[], const double &c[])
     {
      if(i <= first)
         return h[i] - l[i];
      return MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - c[i - 1]), MathAbs(l[i] - c[i - 1])));
     }

   double            PlusDmAt(const int i, const double &h[], const double &l[])
     {
      double up = h[i] - h[i - 1], down = l[i - 1] - l[i];
      return (up > down && up > 0.0) ? up : 0.0;
     }

   double            MinusDmAt(const int i, const double &h[], const double &l[])
     {
      double up = h[i] - h[i - 1], down = l[i - 1] - l[i];
      return (down > up && down > 0.0) ? down : 0.0;
     }

   // TradingView ta.ema: seeded with an SMA of the first `len` closes.
   double            EmaAt(const int i, const int len, const double &c[], const double &buf[])
     {
      int k = i - first;
      if(k < len - 1)
         return EMPTY_VALUE;
      if(k == len - 1)
        {
         double s = 0.0;
         for(int j = i - len + 1; j <= i; j++)
            s += c[j];
         return s / len;
        }
      if(buf[i - 1] == EMPTY_VALUE)
         return EMPTY_VALUE;
      double alpha = 2.0 / (len + 1);
      return alpha * c[i] + (1.0 - alpha) * buf[i - 1];
     }

   //--- Indicator values of bar i from bar i-1 (also called on every tick for the open candle).
   void              Step(const int i, const double &h[], const double &l[], const double &c[])
     {
      int k = i - first;
      int p = InpAtrPeriod;
      double a = EMPTY_VALUE;
      if(k == p - 1)
        {
         double s = 0.0;
         for(int j = i - p + 1; j <= i; j++)
            s += TrAt(j, h, l, c);
         a = s / p;
        }
      else
         if(k >= p && atr[i - 1] != EMPTY_VALUE)
            a = (atr[i - 1] * (p - 1) + TrAt(i, h, l, c)) / p;
      atr[i] = a;

      //--- Supertrend (ta.supertrend)
      int d = 0;
      double s1 = EMPTY_VALUE;
      upper[i] = EMPTY_VALUE;
      lower[i] = EMPTY_VALUE;
      if(a != EMPTY_VALUE)
        {
         double upPrev = (k > 0 && upper[i - 1] != EMPTY_VALUE) ? upper[i - 1] : 0.0;
         double loPrev = (k > 0 && lower[i - 1] != EMPTY_VALUE) ? lower[i - 1] : 0.0;
         double src = (h[i] + l[i]) / 2.0;
         double up = src + InpFactor * a;
         double lo = src - InpFactor * a;
         double prevClose = k > 0 ? c[i - 1] : c[i];
         lo = (lo > loPrev || prevClose < loPrev) ? lo : loPrev;
         up = (up < upPrev || prevClose > upPrev) ? up : upPrev;
         if(k == 0 || atr[i - 1] == EMPTY_VALUE)
            d = 1;
         else
            if(st[i - 1] == upper[i - 1])
               d = c[i] > up ? -1 : 1;
            else
               d = c[i] < lo ? 1 : -1;
         s1 = d == -1 ? lo : up;
         upper[i] = up;
         lower[i] = lo;
        }
      st[i] = s1;
      dir[i] = d;

      //--- ADX (ta.dmi)
      int L = InpAdxLength, S = InpAdxSmoothing;
      double tr1 = EMPTY_VALUE, p1 = EMPTY_VALUE, m1 = EMPTY_VALUE;
      if(k == L - 1)
        {
         double s = 0.0;
         for(int j = i - L + 1; j <= i; j++)
            s += TrAt(j, h, l, c);
         tr1 = s / L;
        }
      else
         if(k >= L && trur[i - 1] != EMPTY_VALUE)
            tr1 = (trur[i - 1] * (L - 1) + TrAt(i, h, l, c)) / L;
      if(k == L)
        {
         double sp = 0.0, sm = 0.0;
         for(int j = i - L + 1; j <= i; j++)
           {
            sp += PlusDmAt(j, h, l);
            sm += MinusDmAt(j, h, l);
           }
         p1 = sp / L;
         m1 = sm / L;
        }
      else
         if(k > L && ps[i - 1] != EMPTY_VALUE)
           {
            p1 = (ps[i - 1] * (L - 1) + PlusDmAt(i, h, l)) / L;
            m1 = (ms[i - 1] * (L - 1) + MinusDmAt(i, h, l)) / L;
           }
      trur[i] = tr1;
      ps[i] = p1;
      ms[i] = m1;
      double x = EMPTY_VALUE;
      if(tr1 != EMPTY_VALUE && p1 != EMPTY_VALUE)
        {
         if(tr1 == 0.0)
            x = 0.0;
         else
           {
            double pdi = 100.0 * p1 / tr1, mdi = 100.0 * m1 / tr1;
            double sum = pdi + mdi;
            x = MathAbs(pdi - mdi) / (sum != 0.0 ? sum : 1.0);
           }
        }
      dx[i] = x;
      double ar = EMPTY_VALUE;
      if(k == L + S - 1)
        {
         double s = 0.0;
         bool ok = true;
         for(int j = i - S + 1; j <= i; j++)
           {
            if(dx[j] == EMPTY_VALUE)
               ok = false;
            else
               s += dx[j];
           }
         if(ok)
            ar = s / S;
        }
      else
         if(k > L + S - 1 && adxRaw[i - 1] != EMPTY_VALUE)
            ar = x == EMPTY_VALUE ? adxRaw[i - 1] : (adxRaw[i - 1] * (S - 1) + x) / S;
      adxRaw[i] = ar;
      adx[i] = ar == EMPTY_VALUE ? EMPTY_VALUE : 100.0 * ar;

      //--- EMAs
      ema200[i] = EmaAt(i, 200, c, ema200);
      emaRe[i] = EmaAt(i, MathMax(1, InpReentryEmaLength), c, emaRe);
     }

   double            PlusDi(const int i)  { return (trur[i] != EMPTY_VALUE && trur[i] > 0.0 && ps[i] != EMPTY_VALUE) ? 100.0 * ps[i] / trur[i] : EMPTY_VALUE; }
   double            MinusDi(const int i) { return (trur[i] != EMPTY_VALUE && trur[i] > 0.0 && ms[i] != EMPTY_VALUE) ? 100.0 * ms[i] / trur[i] : EMPTY_VALUE; }

   void              RecResolve(const double r, const bool win)
     {
      if(recCount == 0)
         return;
      recs[recCount - 1].resolved = true;
      recs[recCount - 1].win = win;
      recs[recCount - 1].statR = r;
     }

   void              RecHistory(const string outcome, const double r, const bool slTouched)
     {
      if(histRecorded || recCount == 0)
         return;
      recs[recCount - 1].histDone = true;
      recs[recCount - 1].outcome = outcome;
      recs[recCount - 1].histR = r;
      recs[recCount - 1].slHit = slTouched;
      histRecorded = true;
     }

   void              NewTrade(const int side, const int i, const datetime t, const double c, const double a)
     {
      entry = c;
      double risk = a * InpSlAtrMult;
      sl = c - side * risk;
      tp1 = c + side * risk * InpTp1R;
      tp2 = c + side * risk * InpTp2R;
      tp3 = c + side * risk * InpTp3R;
      tDir = side;
      tradeBar = i;
      tp1Reached = false;
      tp2Reached = false;
      tp3Reached = false;
      resolved = false;
      histRecorded = false;
      reLongArmed = false;
      reShortArmed = false;
      emaLongPull = false;
      emaShortPull = false;
      if(recCount >= ArraySize(recs))
         ArrayResize(recs, recCount + 256);
      recs[recCount].time = t;
      recs[recCount].side = side;
      recs[recCount].resolved = false;
      recs[recCount].win = false;
      recs[recCount].statR = 0.0;
      recs[recCount].histDone = false;
      recs[recCount].outcome = "";
      recs[recCount].histR = 0.0;
      recs[recCount].slHit = false;
      recCount++;
     }

   string            MaxTpText() { return tp3Reached ? "TP3" : tp2Reached ? "TP2" : "TP1"; }
   double            MaxTpR()    { return tp3Reached ? InpTp3R : tp2Reached ? InpTp2R : InpTp1R; }

   //--- Pivot confirmed on bar i (pivot bar = i - L). Left side strictly lower/higher.
   double            PivotHighAt(const int i, const double &h[])
     {
      int L = InpPivotLength, p = i - L;
      if(p - L < first)
         return EMPTY_VALUE;
      for(int j = p - L; j <= p + L; j++)
        {
         if(j == p)
            continue;
         if(j < p ? h[j] >= h[p] : h[j] > h[p])
            return EMPTY_VALUE;
        }
      return h[p];
     }

   double            PivotLowAt(const int i, const double &l[])
     {
      int L = InpPivotLength, p = i - L;
      if(p - L < first)
         return EMPTY_VALUE;
      for(int j = p - L; j <= p + L; j++)
        {
         if(j == p)
            continue;
         if(j < p ? l[j] <= l[p] : l[j] < l[p])
            return EMPTY_VALUE;
        }
      return l[p];
     }

   // Value of the line through two pivots at bar x (EMPTY if no line).
   double            LineAt(const int b1, const double p1, const int b2, const double p2, const int x)
     {
      if(b1 < 0 || b2 < 0 || b1 == b2 || p1 == EMPTY_VALUE || p2 == EMPTY_VALUE)
         return EMPTY_VALUE;
      return p1 + (p2 - p1) / (b2 - b1) * (x - b1);
     }

   // Upper / lower breakout boundaries at bar x (same construction as the TradingView script).
   void              BreakoutBounds(const int x, double &up, double &lo)
     {
      double supNow = LineAt(prevSupB, prevSupP, lastSupB, lastSupP, x);
      double resNow = LineAt(prevResB, prevResP, lastResB, lastResP, x);
      double supAtRes = lastResB >= 0 ? LineAt(prevSupB, prevSupP, lastSupB, lastSupP, lastResB) : EMPTY_VALUE;
      double resAtSup = lastSupB >= 0 ? LineAt(prevResB, prevResP, lastResB, lastResP, lastSupB) : EMPTY_VALUE;
      double upWidth = (supAtRes != EMPTY_VALUE && lastResP != EMPTY_VALUE) ? lastResP - supAtRes : EMPTY_VALUE;
      double downWidth = (resAtSup != EMPTY_VALUE && lastSupP != EMPTY_VALUE) ? resAtSup - lastSupP : EMPTY_VALUE;
      bool upValid = upWidth != EMPTY_VALUE && upWidth > 0.0 && supNow != EMPTY_VALUE;
      bool downValid = downWidth != EMPTY_VALUE && downWidth > 0.0 && resNow != EMPTY_VALUE;
      up = upValid ? supNow + upWidth : resNow;
      lo = downValid ? resNow - downWidth : supNow;
     }

   void              AddKeyLevel(double &prices[], int &bars[], const double price, const int bar, const double tol)
     {
      int n = ArraySize(prices);
      int match = -1;
      double best = 0.0;
      for(int j = 0; j < n; j++)
        {
         double dist = MathAbs(prices[j] - price);
         if(dist <= tol && (match < 0 || dist < best))
           {
            match = j;
            best = dist;
           }
        }
      if(match >= 0)
        {
         prices[match] = (prices[match] + price) / 2.0;
         return;
        }
      ArrayResize(prices, n + 1);
      ArrayResize(bars, n + 1);
      for(int j = n; j > 0; j--)
        {
         prices[j] = prices[j - 1];
         bars[j] = bars[j - 1];
        }
      prices[0] = price;
      bars[0] = bar;
      if(ArraySize(prices) > InpKeyLevelsCount)
        {
         ArrayResize(prices, InpKeyLevelsCount);
         ArrayResize(bars, InpKeyLevelsCount);
        }
     }

   //--- Signals and the virtual trade on closed bar i.
   void              Closed(const int i, const datetime &t[], const double &h[], const double &l[], const double &c[], BarEvents &ev)
     {
      ClearEvents(ev);
      lastClosed = i;
      int L = InpPivotLength;
      double pivHigh = PivotHighAt(i, h);
      double pivLow = PivotLowAt(i, l);
      if(pivLow != EMPTY_VALUE)
        {
         prevSupP = lastSupP;
         prevSupB = lastSupB;
         lastSupP = pivLow;
         lastSupB = i - L;
        }
      if(pivHigh != EMPTY_VALUE)
        {
         prevResP = lastResP;
         prevResB = lastResB;
         lastResP = pivHigh;
         lastResB = i - L;
        }

      int d0 = (int)dir[i];
      int d1 = (int)dir[i - 1];
      bool up = d0 < 0, dn = d0 > 0;
      double s0 = st[i];
      double ema = emaRe[i], emaPrev = emaRe[i - 1];
      bool emaOk = ema != EMPTY_VALUE && emaPrev != EMPTY_VALUE;
      bool emaCrossUp = emaOk && c[i] > ema && c[i - 1] <= emaPrev;
      bool emaCrossDown = emaOk && c[i] < ema && c[i - 1] >= emaPrev;

      bool stBuy = d0 < 0 && d1 > 0;
      bool stSell = d0 > 0 && d1 < 0;
      bool reBuy = InpReentrySt && reLongArmed && up && s0 != EMPTY_VALUE && l[i] <= s0 && c[i] > s0;
      bool reSell = InpReentrySt && reShortArmed && dn && s0 != EMPTY_VALUE && h[i] >= s0 && c[i] < s0;
      bool emaReBuy = InpReentryEma && reLongArmed && up && emaLongPull && emaCrossUp;
      bool emaReSell = InpReentryEma && reShortArmed && dn && emaShortPull && emaCrossDown;
      bool fastBuy = InpReentryEmaFast && reLongArmed && up && ema != EMPTY_VALUE && l[i] <= ema && c[i] > ema;
      bool fastSell = InpReentryEmaFast && reShortArmed && dn && ema != EMPTY_VALUE && h[i] >= ema && c[i] < ema;
      bool boBuy = false, boSell = false;
      if(InpBreakoutSignals)
        {
         double upNow = EMPTY_VALUE, loNow = EMPTY_VALUE, upPrev = EMPTY_VALUE, loPrev = EMPTY_VALUE;
         BreakoutBounds(i, upNow, loNow);
         BreakoutBounds(i - 1, upPrev, loPrev);
         boBuy = upNow != EMPTY_VALUE && upPrev != EMPTY_VALUE && c[i] > upNow && c[i - 1] <= upPrev;
         boSell = loNow != EMPTY_VALUE && loPrev != EMPTY_VALUE && c[i] < loNow && c[i - 1] >= loPrev;
        }

      bool adxOk = !InpUseAdxFilter || (adx[i] != EMPTY_VALUE && adx[i] > InpAdxSignalMin);
      bool emaLongOk = !InpUseEma200Filter || (ema200[i] != EMPTY_VALUE && c[i] > ema200[i]);
      bool emaShortOk = !InpUseEma200Filter || (ema200[i] != EMPTY_VALUE && c[i] < ema200[i]);
      bool htfLongOk = true, htfShortOk = true;
      if(htfOn)
        {
         int hd = HtfDirAt(t[i]);
         htfLongOk = hd < 0;
         htfShortOk = hd > 0;
        }
      bool buy = (stBuy || boBuy || reBuy || emaReBuy || fastBuy) && adxOk && emaLongOk && htfLongOk;
      bool sell = (stSell || boSell || reSell || emaReSell || fastSell) && adxOk && emaShortOk && htfShortOk;
      if(InpReentryEma && reLongArmed && up && emaCrossDown)
         emaLongPull = true;
      if(InpReentryEma && reShortArmed && dn && emaCrossUp)
         emaShortPull = true;

      //--- Open virtual trade: SL first, then TP1 (whole trade closed at TP1 / SL / reversal for the statistics)
      if(tDir != 0 && !resolved)
        {
         bool slTouch = tDir == 1 ? l[i] <= sl : h[i] >= sl;
         bool tp1Touch = tDir == 1 ? h[i] >= tp1 : l[i] <= tp1;
         if(slTouch)
           {
            ev.slHit = true;
            ev.slPrice = sl;
            RecResolve(-1.0, false);
            RecHistory("SL", -1.0, true);
            resolved = true;
            tDir = 0;
           }
         else
            if(tp1Touch)
              {
               RecResolve(InpTp1R, true);
               resolved = true;
              }
        }
      //--- After TP1 the trade runs toward TP2/TP3; back to the original SL ends it.
      if(tDir != 0 && tp1Reached)
        {
         bool slTouch = tDir == 1 ? l[i] <= sl : h[i] >= sl;
         if(slTouch)
           {
            ev.slHit = true;
            ev.slPrice = sl;
            RecHistory(MaxTpText() + "→SL", MaxTpR(), true);
            tDir = 0;
           }
        }
      if(tDir != 0)
        {
         bool isLong = tDir == 1;
         if(!tp1Reached && (isLong ? h[i] >= tp1 : l[i] <= tp1))
           {
            tp1Reached = true;
            ev.tpHit[0] = true;
            ev.tpPrice[0] = tp1;
           }
         if(!tp2Reached && (isLong ? h[i] >= tp2 : l[i] <= tp2))
           {
            tp2Reached = true;
            ev.tpHit[1] = true;
            ev.tpPrice[1] = tp2;
           }
         if(!tp3Reached && (isLong ? h[i] >= tp3 : l[i] <= tp3))
           {
            tp3Reached = true;
            ev.tpHit[2] = true;
            ev.tpPrice[2] = tp3;
            if(isLong)
              {
               reLongArmed = true;
               emaLongPull = false;
              }
            else
              {
               reShortArmed = true;
               emaShortPull = false;
              }
            RecHistory("TP3", InpTp3R, false);
           }
        }

      //--- A new signal while the previous trade is still open: close it at this candle's close.
      double risk = (entry != EMPTY_VALUE && sl != EMPTY_VALUE) ? MathAbs(entry - sl) : 0.0;
      double reversalR = (tDir != 0 && risk > 0.0) ? (c[i] - entry) * tDir / risk : 0.0;
      if((buy || sell) && tDir != 0 && !resolved)
        {
         RecResolve(reversalR, reversalR > 0.0);
         resolved = true;
        }
      if((buy || sell) && tDir != 0 && !histRecorded)
        {
         string outcome = tp3Reached ? "TP3" : tp2Reached ? "TP2" : tp1Reached ? "TP1" : "REV";
         double r = tp3Reached ? InpTp3R : tp2Reached ? InpTp2R : tp1Reached ? InpTp1R : reversalR;
         RecHistory(outcome, r, false);
        }

      if(buy && atr[i] != EMPTY_VALUE)
         NewTrade(1, i, t[i], c[i], atr[i]);
      if(sell && atr[i] != EMPTY_VALUE)
         NewTrade(-1, i, t[i], c[i], atr[i]);
      ev.buy = buy && atr[i] != EMPTY_VALUE;
      ev.sell = sell && atr[i] != EMPTY_VALUE;

      if(InpShowKeyLevels && atr[i] != EMPTY_VALUE)
        {
         double tol = atr[i] * InpKeyLevelTolAtr;
         if(pivLow != EMPTY_VALUE)
            AddKeyLevel(kSupPrice, kSupBar, pivLow, i - L, tol);
         if(pivHigh != EMPTY_VALUE)
            AddKeyLevel(kResPrice, kResBar, pivHigh, i - L, tol);
        }
     }

   // Statistics of the signals that started at or after `cutoff`.
   void              Stats(const datetime cutoff, int &signals, int &wins, int &losses, double &sumR)
     {
      signals = 0;
      wins = 0;
      losses = 0;
      sumR = 0.0;
      for(int k = 0; k < recCount; k++)
        {
         if(recs[k].time < cutoff)
            continue;
         signals++;
         if(!recs[k].resolved)
            continue;
         sumR += recs[k].statR;
         if(recs[k].win)
            wins++;
         else
            losses++;
        }
     }
  };

//--- State
CEngine  g_eng;
string   g_prefix = "";
bool     g_haveData = false;
double   g_dashAdx = EMPTY_VALUE, g_dashPlusDi = EMPTY_VALUE, g_dashMinusDi = EMPTY_VALUE;
int      g_dashDir = 0;
datetime g_dashNow = 0;
// Win rate per timeframe table
ENUM_TIMEFRAMES g_tfList[5] = {PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
datetime g_tfLast[5];
bool     g_tfOk[5];
int      g_tfSignals[5], g_tfWins[5], g_tfLosses[5];
double   g_tfSumR[5];
datetime g_tfComputed = 0;
string   g_geoState = "";

//+------------------------------------------------------------------+
//| Chart objects                                                    |
//+------------------------------------------------------------------+
bool ObjEnsure(const string name, const ENUM_OBJECT type, const datetime t1, const double p1, const datetime t2 = 0, const double p2 = 0.0)
  {
   if(ObjectFind(0, name) >= 0)
      return true;
   bool ok = (type == OBJ_TREND || type == OBJ_RECTANGLE) ? ObjectCreate(0, name, type, 0, t1, p1, t2, p2)
                                                          : ObjectCreate(0, name, type, 0, t1, p1);
   if(!ok)
      LogOnce(LOG_ERRORS, "obj" + IntegerToString(GetLastError()) + EnumToString(type),
              StringFormat("วาดวัตถุ %s (%s) ไม่สำเร็จ error %d", name, EnumToString(type), GetLastError()));
   return ok;
  }

void ObjText(const string name, const datetime t, const double price, const string text, const color clr,
             const int size, const ENUM_ANCHOR_POINT anchor, const string tip = "")
  {
   if(!ObjEnsure(name, OBJ_TEXT, t, price))
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Tahoma");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip == "" ? text : tip);
  }

void ObjLine(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
             const color clr, const ENUM_LINE_STYLE style, const int width, const bool rayRight)
  {
   if(!ObjEnsure(name, OBJ_TREND, t1, p1, t2, p2))
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, rayRight);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

void ObjBox(const string name, const datetime t1, const double p1, const datetime t2, const double p2, const color clr)
  {
   if(!ObjEnsure(name, OBJ_RECTANGLE, t1, p1, t2, p2))
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void ObjDelete(const string name)
  {
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
  }

//+------------------------------------------------------------------+
//| Drawing of one closed bar, the latest trade and the patterns     |
//+------------------------------------------------------------------+
void DrawBarEvents(const int i, const datetime &time[], const double &h[], const double &l[], const double &c[], const BarEvents &ev)
  {
   string id = IntegerToString((long)time[i]);
   bool isLong = g_eng.tDir >= 0;
   if(InpShowTpMarks)
     {
      color tpClr[3];
      tpClr[0] = InpTp1Color;
      tpClr[1] = InpTp2Color;
      tpClr[2] = InpTp3Color;
      for(int k = 0; k < 3; k++)
         if(ev.tpHit[k])
            ObjText(g_prefix + "tp" + IntegerToString(k + 1) + "_" + id, time[i], ev.tpPrice[k], "✓ TP" + IntegerToString(k + 1), tpClr[k], 7,
                    isLong ? ANCHOR_UPPER : ANCHOR_LOWER);
      if(ev.slHit)
         ObjText(g_prefix + "sl_" + id, time[i], ev.slPrice, "✗ SL", InpSlColor, 7, ANCHOR_CENTER);
     }
   if(InpShowSignals)
     {
      if(ev.buy)
         ObjText(g_prefix + "buy_" + id, time[i], l[i], "BUY", InpUpColor, 7, ANCHOR_UPPER,
                 "BUY " + Fmt(c[i]) + " · " + TimeToString(time[i], TIME_DATE | TIME_MINUTES));
      if(ev.sell)
         ObjText(g_prefix + "sell_" + id, time[i], h[i], "SELL", InpDownColor, 7, ANCHOR_LOWER,
                 "SELL " + Fmt(c[i]) + " · " + TimeToString(time[i], TIME_DATE | TIME_MINUTES));
     }
  }

void DrawTradeObjects(const int ratesTotal, const datetime &time[])
  {
   string names[] = {"lvE", "lvT1", "lvT2", "lvT3", "lvS", "pxE", "pxT1", "pxT2", "pxT3", "pxS", "bxT1", "bxT2", "bxT3", "bxS"};
   if(g_eng.entry == EMPTY_VALUE || g_eng.tradeBar < 0)
     {
      for(int k = 0; k < ArraySize(names); k++)
         ObjDelete(g_prefix + names[k]);
      return;
     }
   int sec = PeriodSeconds();
   datetime t1 = time[g_eng.tradeBar];
   datetime tEnd = (datetime)((long)time[ratesTotal - 1] + (long)sec * InpPriceLabelOffset);
   double lv[5];
   lv[0] = g_eng.entry;
   lv[1] = g_eng.tp1;
   lv[2] = g_eng.tp2;
   lv[3] = g_eng.tp3;
   lv[4] = g_eng.sl;
   color cl[5];
   cl[0] = InpEntryColor;
   cl[1] = InpTp1Color;
   cl[2] = InpTp2Color;
   cl[3] = InpTp3Color;
   cl[4] = InpSlColor;
   string title[5] = {"Entry", "TP1", "TP2", "TP3", "SL"};
   for(int k = 0; k < 5; k++)
     {
      if(InpShowLevels)
         ObjLine(g_prefix + names[k], t1, lv[k], tEnd, lv[k], cl[k], STYLE_DASH, (k == 0 || k == 4) ? 2 : 1, false);
      else
         ObjDelete(g_prefix + names[k]);
      if(InpShowPriceLabels)
         ObjText(g_prefix + names[5 + k], tEnd, lv[k], "  " + title[k] + "  " + Fmt(lv[k]), cl[k], 8, ANCHOR_LEFT);
      else
         ObjDelete(g_prefix + names[5 + k]);
     }
   color bg = ChartBg();
   if(InpShowBoxes)
     {
      ObjBox(g_prefix + "bxT1", t1, g_eng.entry, tEnd, g_eng.tp1, Blend(InpTp1Color, bg, 0.18));
      ObjBox(g_prefix + "bxT2", t1, g_eng.tp1, tEnd, g_eng.tp2, Blend(InpTp2Color, bg, 0.13));
      ObjBox(g_prefix + "bxT3", t1, g_eng.tp2, tEnd, g_eng.tp3, Blend(InpTp3Color, bg, 0.10));
      ObjBox(g_prefix + "bxS", t1, g_eng.entry, tEnd, g_eng.sl, Blend(InpSlColor, bg, 0.15));
     }
   else
      for(int k = 10; k < 14; k++)
         ObjDelete(g_prefix + names[k]);
  }

void DrawPatternObjects(const int ratesTotal, const datetime &time[])
  {
   int sec = PeriodSeconds();
   int d0 = (int)g_eng.dir[ratesTotal - 1];
   //--- Key levels
   for(int j = 0; j < 5; j++)
     {
      string ns = g_prefix + "kS" + IntegerToString(j);
      string nr = g_prefix + "kR" + IntegerToString(j);
      if(InpShowKeyLevels && j < ArraySize(g_eng.kSupPrice) && g_eng.kSupBar[j] >= 0)
         ObjLine(ns, time[g_eng.kSupBar[j]], g_eng.kSupPrice[j], (datetime)((long)time[g_eng.kSupBar[j]] + sec), g_eng.kSupPrice[j], InpSupportColor, STYLE_DOT, 1, true);
      else
         ObjDelete(ns);
      if(InpShowKeyLevels && j < ArraySize(g_eng.kResPrice) && g_eng.kResBar[j] >= 0)
         ObjLine(nr, time[g_eng.kResBar[j]], g_eng.kResPrice[j], (datetime)((long)time[g_eng.kResBar[j]] + sec), g_eng.kResPrice[j], InpResistanceColor, STYLE_DOT, 1, true);
      else
         ObjDelete(nr);
     }
   //--- Diagonal trend lines through the last two pivots
   bool risingSupport = g_eng.prevSupB >= 0 && g_eng.lastSupB >= 0 && g_eng.lastSupP > g_eng.prevSupP;
   bool fallingResistance = g_eng.prevResB >= 0 && g_eng.lastResB >= 0 && g_eng.lastResP < g_eng.prevResP;
   bool allowSup = InpShowTrendlines && g_eng.prevSupB >= 0 && g_eng.lastSupB >= 0 && (!InpOnlyCurrentSlope || (d0 < 0 && risingSupport));
   bool allowRes = InpShowTrendlines && g_eng.prevResB >= 0 && g_eng.lastResB >= 0 && (!InpOnlyCurrentSlope || (d0 > 0 && fallingResistance));
   if(allowSup)
      ObjLine(g_prefix + "tlS", time[g_eng.prevSupB], g_eng.prevSupP, time[g_eng.lastSupB], g_eng.lastSupP, InpSupportColor, STYLE_SOLID, 2, true);
   else
      ObjDelete(g_prefix + "tlS");
   if(allowRes)
      ObjLine(g_prefix + "tlR", time[g_eng.prevResB], g_eng.prevResP, time[g_eng.lastResB], g_eng.lastResP, InpResistanceColor, STYLE_SOLID, 2, true);
   else
      ObjDelete(g_prefix + "tlR");
   //--- Parallel channel
   string chName = g_prefix + "chan";
   bool drawn = false;
   if(InpShowChannel)
     {
      double supAtRes = g_eng.lastResB >= 0 ? g_eng.LineAt(g_eng.prevSupB, g_eng.prevSupP, g_eng.lastSupB, g_eng.lastSupP, g_eng.lastResB) : EMPTY_VALUE;
      double resAtSup = g_eng.lastSupB >= 0 ? g_eng.LineAt(g_eng.prevResB, g_eng.prevResP, g_eng.lastResB, g_eng.lastResP, g_eng.lastSupB) : EMPTY_VALUE;
      bool supValid = supAtRes != EMPTY_VALUE && g_eng.lastResP != EMPTY_VALUE && g_eng.lastResP > supAtRes
                      && (!InpOnlyCurrentSlope || (d0 < 0 && g_eng.lastSupP > g_eng.prevSupP));
      bool resValid = resAtSup != EMPTY_VALUE && g_eng.lastSupP != EMPTY_VALUE && g_eng.lastSupP < resAtSup
                      && (!InpOnlyCurrentSlope || (d0 > 0 && g_eng.lastResP < g_eng.prevResP));
      if(supValid || resValid)
        {
         int b1, b2;
         double p1, p2, width;
         if(supValid)
           {
            b1 = g_eng.prevSupB;
            b2 = g_eng.lastSupB;
            p1 = g_eng.prevSupP;
            p2 = g_eng.lastSupP;
            width = g_eng.lastResP - supAtRes;
           }
         else
           {
            b1 = g_eng.prevResB;
            b2 = g_eng.lastResB;
            p1 = g_eng.prevResP;
            p2 = g_eng.lastResP;
            width = -(resAtSup - g_eng.lastSupP);
           }
         bool ok = ObjectFind(0, chName) >= 0 || ObjectCreate(0, chName, OBJ_CHANNEL, 0, time[b1], p1, time[b2], p2, time[b1], p1 + width);
         if(!ok)
            LogOnce(LOG_ERRORS, "chan" + IntegerToString(GetLastError()), StringFormat("วาดกรอบราคาไม่สำเร็จ error %d", GetLastError()));
         else
           {
            ObjectSetInteger(0, chName, OBJPROP_TIME, 0, time[b1]);
            ObjectSetDouble(0, chName, OBJPROP_PRICE, 0, p1);
            ObjectSetInteger(0, chName, OBJPROP_TIME, 1, time[b2]);
            ObjectSetDouble(0, chName, OBJPROP_PRICE, 1, p2);
            ObjectSetInteger(0, chName, OBJPROP_TIME, 2, time[b1]);
            ObjectSetDouble(0, chName, OBJPROP_PRICE, 2, p1 + width);
            ObjectSetInteger(0, chName, OBJPROP_COLOR, InpChannelColor);
            ObjectSetInteger(0, chName, OBJPROP_FILL, true);
            ObjectSetInteger(0, chName, OBJPROP_BACK, true);
            ObjectSetInteger(0, chName, OBJPROP_RAY_RIGHT, true);
            ObjectSetInteger(0, chName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, chName, OBJPROP_HIDDEN, true);
            drawn = true;
            Log(LOG_DETAIL, StringFormat("กรอบราคา: %s %s → %s %s กว้าง %s", TimeToString(time[b1]), Fmt(p1), TimeToString(time[b2]), Fmt(p2), Fmt(width)));
           }
        }
     }
   if(!drawn)
      ObjDelete(chName);
  }

//+------------------------------------------------------------------+
//| Dashboards (tables made of labels, stacked per chart corner)     |
//+------------------------------------------------------------------+
string g_tTxt[];
color  g_tClr[];
string g_tTip[];
int    g_tCols = 1;
int    g_stack[4];
int    g_cornerW[4];
string g_geoNow = "";

void TBegin(const int cols)
  {
   g_tCols = cols;
   ArrayResize(g_tTxt, 0);
   ArrayResize(g_tClr, 0);
   ArrayResize(g_tTip, 0);
  }

void TCell(const string text, const color clr, const string tip = "")
  {
   int n = ArraySize(g_tTxt);
   ArrayResize(g_tTxt, n + 1);
   ArrayResize(g_tClr, n + 1);
   ArrayResize(g_tTip, n + 1);
   g_tTxt[n] = text;
   g_tClr[n] = clr;
   g_tTip[n] = tip;
  }

void TEnd(const string id, const ENUM_BASE_CORNER corner)
  {
   string pfx = g_prefix + "D" + id + "_";
   ObjectsDeleteAll(0, pfx);
   int n = ArraySize(g_tTxt);
   if(n == 0)
      return;
   int rows = (n + g_tCols - 1) / g_tCols;
   int fs = MathMax(6, InpDashFontSize);
   int rowH = fs * 2 + 3;
   double charW = fs * 0.85 + 0.5;
   int colW[];
   ArrayResize(colW, g_tCols);
   ArrayInitialize(colW, 0);
   for(int k = 0; k < n; k++)
     {
      int w = (int)(StringLen(g_tTxt[k]) * charW) + 12;
      if(w > colW[k % g_tCols])
         colW[k % g_tCols] = w;
     }
   int W = 8;
   for(int c = 0; c < g_tCols; c++)
      W += colW[c];
   int H = rows * rowH + 6;
   bool isRight = corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER;
   bool isLower = corner == CORNER_LEFT_LOWER || corner == CORNER_RIGHT_LOWER;
   int x0 = 10;
   int y0 = (isLower ? 10 : 20) + g_stack[(int)corner];
   g_stack[(int)corner] += H + 6;
   if(W + x0 > g_cornerW[(int)corner])
      g_cornerW[(int)corner] = W + x0;
   g_geoNow += StringFormat("%s:%s %dx%d y%d; ", id, EnumToString(corner), W, H, y0);

   color bg = Blend(ChartBg(), ChartFg(), 0.88);
   string bgName = pfx + "bg";
   if(ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, corner);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, isRight ? x0 + W : x0);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, isLower ? y0 + H : y0);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, W);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, H);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_COLOR, bg);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
     }
   else
      LogOnce(LOG_ERRORS, "tblbg" + IntegerToString(GetLastError()), StringFormat("วาดพื้นตาราง %s ไม่สำเร็จ error %d", id, GetLastError()));

   for(int k = 0; k < n; k++)
     {
      if(g_tTxt[k] == "")
         continue;
      int r = k / g_tCols, c = k % g_tCols;
      int colX = 6;
      for(int j = 0; j < c; j++)
         colX += colW[j];
      int rowY = 3 + r * rowH;
      string name = pfx + IntegerToString(k);
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
        {
         LogOnce(LOG_ERRORS, "tbl" + IntegerToString(GetLastError()), StringFormat("วาดข้อความตาราง %s ไม่สำเร็จ error %d", id, GetLastError()));
         continue;
        }
      ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, isRight ? x0 + W - colX : x0 + colX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, isLower ? y0 + H - rowY : y0 + rowY);
      ObjectSetString(0, name, OBJPROP_TEXT, g_tTxt[k]);
      ObjectSetString(0, name, OBJPROP_FONT, "Tahoma");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fs);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_tClr[k]);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, g_tTip[k] == "" ? g_tTxt[k] : g_tTip[k]);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

// Warn (once per layout) when the tables do not fit on the chart or overlap.
void CheckLayout()
  {
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   string warn = "";
   if(cw > 0 && ch > 0)
     {
      if(g_cornerW[CORNER_LEFT_UPPER] + g_cornerW[CORNER_RIGHT_UPPER] > cw)
         warn += "ตารางมุมซ้ายบนกับขวาบนกว้างรวมเกินจอ อาจทับกัน; ";
      if(g_cornerW[CORNER_LEFT_LOWER] + g_cornerW[CORNER_RIGHT_LOWER] > cw)
         warn += "ตารางมุมซ้ายล่างกับขวาล่างกว้างรวมเกินจอ อาจทับกัน; ";
      if(g_stack[CORNER_LEFT_UPPER] + g_stack[CORNER_LEFT_LOWER] + 30 > ch)
         warn += "ตารางฝั่งซ้ายสูงรวมเกินจอ อาจทับกัน; ";
      if(g_stack[CORNER_RIGHT_UPPER] + g_stack[CORNER_RIGHT_LOWER] + 30 > ch)
         warn += "ตารางฝั่งขวาสูงรวมเกินจอ อาจทับกัน; ";
     }
   string state = StringFormat("จอ %dx%d · %s", cw, ch, g_geoNow);
   if(state != g_geoState)
     {
      g_geoState = state;
      Log(LOG_DETAIL, "ตำแหน่งตาราง: " + state);
      if(warn != "")
         Log(LOG_NORMAL, "⚠ " + warn + "(ปรับมุมหรือซ่อนบางตารางใน Inputs) · " + state);
     }
  }

string ThState(const int state)
  {
   return state > 0 ? "ขาขึ้น" : state < 0 ? "ขาลง" : "กลาง";
  }

// TradingView trendScore: ADX below the range level = 50 (neutral), uptrend = 50 + ADX, downtrend = 50 - ADX.
double TrendScore(const int d, const double adx)
  {
   if(d == 0 || adx == EMPTY_VALUE || adx < InpAdxRangeLevel)
      return 50.0;
   double b = MathMin(adx, 50.0);
   return d < 0 ? 50.0 + b : 50.0 - b;
  }

// 1 = bullish, -1 = bearish, 0 = neutral
int TrendState(const int d, const double adx)
  {
   double s = TrendScore(d, adx);
   if(s >= 50.0 - InpNeutralZone && s <= 50.0 + InpNeutralZone)
      return 0;
   return d < 0 ? 1 : -1;
  }

string PeriodText()
  {
   switch(InpStatsPeriod)
     {
      case STATS_1H:
         return "1 ชม.";
      case STATS_4H:
         return "4 ชม.";
      case STATS_1D:
         return "1 วัน";
      case STATS_1W:
         return "1 สัปดาห์";
      case STATS_1M:
         return "1 เดือน";
      default:
         return "ทั้งหมด";
     }
  }

int PeriodSecondsOfStats()
  {
   switch(InpStatsPeriod)
     {
      case STATS_1H:
         return 3600;
      case STATS_4H:
         return 4 * 3600;
      case STATS_1D:
         return 86400;
      case STATS_1W:
         return 7 * 86400;
      case STATS_1M:
         return 30 * 86400;
      default:
         return 0;
     }
  }

//--- Win rate per timeframe: run the same engine on each timeframe over the same calendar window.
void ComputeTfTable(const bool force)
  {
   int days = MathMax(1, MathMin(InpTfStatsDays, 365));
   datetime now = TimeCurrent();
   datetime from = (datetime)((long)now - (long)days * 86400);
   for(int k = 0; k < 5; k++)
     {
      ENUM_TIMEFRAMES tf = g_tfList[k];
      int secs = PeriodSeconds(tf);
      int warm = MathMax(300, InpAtrPeriod + InpAdxLength + InpAdxSmoothing + 2 * InpPivotLength + 210);
      datetime start = (datetime)((long)from - (long)secs * warm);
      MqlRates r[];
      int got = CopyRates(_Symbol, tf, start, now, r);
      if(got < warm / 2)
        {
         g_tfOk[k] = false;
         Log(LOG_DETAIL, StringFormat("ตารางเทียบ TF: ข้อมูล %s ยังไม่พร้อม (ได้ %d แท่ง, error %d)", TfName(tf), got, GetLastError()));
         continue;
        }
      if(!force && g_tfOk[k] && r[got - 1].time == g_tfLast[k])
         continue;   // nothing new on this timeframe
      double h[], l[], c[];
      datetime t[];
      ArrayResize(h, got);
      ArrayResize(l, got);
      ArrayResize(c, got);
      ArrayResize(t, got);
      for(int i = 0; i < got; i++)
        {
         h[i] = r[i].high;
         l[i] = r[i].low;
         c[i] = r[i].close;
         t[i] = r[i].time;
        }
      CEngine e;
      e.Init(tf);
      if(e.htfOn && !e.LoadHtf(t[0]))
        {
         g_tfOk[k] = false;
         continue;
        }
      e.Reset(got, 0);
      BarEvents ev;
      for(int i = 0; i < got; i++)
         e.Step(i, h, l, c);
      for(int i = 1; i <= got - 2; i++)
         e.Closed(i, t, h, l, c, ev);
      int sigs = 0, wins = 0, losses = 0;
      double sumR = 0.0;
      e.Stats(from, sigs, wins, losses, sumR);
      g_tfSignals[k] = sigs;
      g_tfWins[k] = wins;
      g_tfLosses[k] = losses;
      g_tfSumR[k] = sumR;
      g_tfLast[k] = r[got - 1].time;
      g_tfOk[k] = true;
      Log(LOG_DETAIL, StringFormat("ตารางเทียบ TF %s: %d แท่ง สัญญาณ %d ชนะ %d แพ้ %d กำไร %.2fR", TfName(tf), got,
                                   g_tfSignals[k], g_tfWins[k], g_tfLosses[k], g_tfSumR[k]));
     }
   g_tfComputed = now;
  }

void DrawDashboards()
  {
   if(!InpDrawObjects)
      return;
   ArrayInitialize(g_stack, 0);
   ArrayInitialize(g_cornerW, 0);
   g_geoNow = "";
   color fg = ChartFg();
   color headClr = InpEntryColor;
   bool hideAll = InpHideAllDashboards || !g_haveData;

   //--- Statistics of this chart's timeframe
   if(!hideAll && InpStatsMode != DASH_HIDDEN)
     {
      int secs = PeriodSecondsOfStats();
      datetime cutoff = secs > 0 ? (datetime)((long)g_dashNow - secs) : 0;
      int signals, wins, losses;
      double sumR;
      g_eng.Stats(cutoff, signals, wins, losses, sumR);
      int closed = wins + losses;
      string wr = closed > 0 ? DoubleToString(100.0 * wins / closed, 1) + " %" : "-";
      color pc = sumR >= 0.0 ? InpUpColor : InpDownColor;
      string tipWr = "ชนะ ÷ เทรดที่รู้ผล × 100 · สมมติปิดทั้งหมดที่ TP1 หรือ SL หรือเมื่อเกิดสัญญาณกลับทิศ";
      string tipR = "ผลรวมกำไร/ขาดทุนเป็นหน่วย R (1R = ระยะ SL) · ยังไม่หักสเปรด";
      TBegin(2);
      if(InpStatsMode == DASH_COMPACT)
        {
         TCell("อัตราชนะ " + TfName(PERIOD_CURRENT) + " (" + PeriodText() + ")", headClr, tipWr);
         TCell(wr, fg, tipWr);
         TCell("กำไร", pc, tipR);
         TCell(DoubleToString(sumR, 2) + " R", pc, tipR);
        }
      else
        {
         TCell("สถิติย้อนหลัง " + TfName(PERIOD_CURRENT) + " · " + PeriodText(), headClr, "นับสัญญาณที่เกิดในช่วงเวลาที่เลือก จากแท่งที่คำนวณบนกราฟนี้");
         TCell("", fg);
         TCell("สัญญาณ", fg, "จำนวน BUY + SELL");
         TCell(IntegerToString(signals), fg);
         TCell("รู้ผลแล้ว", fg, "ชนะ + แพ้ (เทรดที่ยังวิ่งอยู่ไม่นับ)");
         TCell(IntegerToString(closed), fg);
         TCell("ชนะ", InpUpColor, "ถึง TP1 ก่อนโดน SL หรือปิดตอนกลับทิศแล้วกำไร");
         TCell(IntegerToString(wins), InpUpColor);
         TCell("แพ้", InpDownColor, "โดน SL ก่อนถึง TP1 หรือปิดตอนกลับทิศแล้วขาดทุน");
         TCell(IntegerToString(losses), InpDownColor);
         TCell("อัตราชนะ", fg, tipWr);
         TCell(wr, fg);
         TCell("กำไร (R)", pc, tipR);
         TCell(DoubleToString(sumR, 2) + " R", pc);
        }
      TEnd("stats", InpStatsCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dstats_");

   //--- Win rate per timeframe
   if(!hideAll && InpTfStatsMode != DASH_HIDDEN)
     {
      int best = -1;
      for(int k = 0; k < 5; k++)
         if(g_tfOk[k] && g_tfWins[k] + g_tfLosses[k] > 0 && (best < 0 || g_tfSumR[k] > g_tfSumR[best]))
            best = k;
      string tip = StringFormat("ใช้สูตรและค่าตั้งเดียวกับกราฟนี้ นับสัญญาณใน %d วันล่าสุดของทุก TF · ★ = กำไร R รวมสูงสุด · ยังไม่หักสเปรด", InpTfStatsDays);
      if(InpTfStatsMode == DASH_COMPACT)
         TBegin(1);
      else
        {
         TBegin(5);
         TCell(StringFormat("เทียบ TF (%d วัน)", InpTfStatsDays), headClr, tip);
         TCell("สัญญาณ", headClr, tip);
         TCell("ชนะ/แพ้", headClr, tip);
         TCell("อัตราชนะ", headClr, tip);
         TCell("กำไร R", headClr, tip);
        }
      for(int k = 0; k < 5; k++)
        {
         string name = TfName(g_tfList[k]) + (k == best ? " ★" : "") + (g_tfList[k] == (ENUM_TIMEFRAMES)_Period ? " •" : "");
         int closed = g_tfWins[k] + g_tfLosses[k];
         string wr = (g_tfOk[k] && closed > 0) ? DoubleToString(100.0 * g_tfWins[k] / closed, 1) + "%" : "-";
         color rc = !g_tfOk[k] ? fg : g_tfSumR[k] >= 0.0 ? InpUpColor : InpDownColor;
         string rText = g_tfOk[k] ? StringFormat("%+.1fR", g_tfSumR[k]) : "รอข้อมูล";
         if(InpTfStatsMode == DASH_COMPACT)
            TCell(name + "  " + wr + "  " + rText, rc, tip);
         else
           {
            TCell(name, k == best ? headClr : fg, tip);
            TCell(g_tfOk[k] ? IntegerToString(g_tfSignals[k]) : "-", fg);
            TCell(g_tfOk[k] ? IntegerToString(g_tfWins[k]) + "/" + IntegerToString(g_tfLosses[k]) : "-", fg);
            TCell(wr, fg);
            TCell(rText, rc);
           }
        }
      TEnd("tfs", InpTfStatsCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dtfs_");

   //--- ADX
   if(!hideAll && InpAdxMode != DASH_HIDDEN)
     {
      double adx = g_dashAdx;
      string phase = adx == EMPTY_VALUE ? "รอข้อมูล" : adx < InpAdxRangeLevel ? "ไซด์เวย์" : adx < InpAdxStrongLevel ? "กำลังเปลี่ยน" : "เทรนด์แรง";
      color phaseClr = adx == EMPTY_VALUE ? fg : adx < InpAdxRangeLevel ? InpDownColor : adx < InpAdxStrongLevel ? fg : InpUpColor;
      bool diOk = g_dashPlusDi != EMPTY_VALUE && g_dashMinusDi != EMPTY_VALUE;
      bool active = adx != EMPTY_VALUE && adx >= InpAdxStrongLevel && diOk
                    && ((g_dashDir < 0 && g_dashPlusDi > g_dashMinusDi) || (g_dashDir > 0 && g_dashMinusDi > g_dashPlusDi));
      string adxText = adx == EMPTY_VALUE ? "-" : DoubleToString(adx, 2);
      string tipAdx = "ความแรงของเทรนด์ 0–100 (ไม่บอกทิศ) · < " + DoubleToString(InpAdxRangeLevel, 0) + " ไซด์เวย์, ≥ "
                      + DoubleToString(InpAdxStrongLevel, 0) + " เทรนด์แรง";
      string tipFilter = "เข้าได้ = ADX ≥ " + DoubleToString(InpAdxStrongLevel, 0) + " และแรงซื้อ/ขายไปทางเดียวกับ Supertrend · แสดงผลอย่างเดียว";
      TBegin(2);
      if(InpAdxMode == DASH_COMPACT)
        {
         TCell("ADX " + adxText, phaseClr, tipAdx);
         TCell(active ? "เข้าได้" : "รอ", active ? InpUpColor : InpDownColor, tipFilter);
        }
      else
        {
         string side = !diOk ? "-" : g_dashPlusDi > g_dashMinusDi ? "ขาขึ้น" : g_dashMinusDi > g_dashPlusDi ? "ขาลง" : "กลาง";
         TCell("ความแรงเทรนด์ (ADX)", headClr);
         TCell("", fg);
         TCell("ADX", fg, tipAdx);
         TCell(adxText, phaseClr);
         TCell("+DI แรงซื้อ", InpUpColor, "ยิ่งสูงยิ่งมีแรงซื้อ");
         TCell(diOk ? DoubleToString(g_dashPlusDi, 2) : "-", InpUpColor);
         TCell("−DI แรงขาย", InpDownColor, "ยิ่งสูงยิ่งมีแรงขาย");
         TCell(diOk ? DoubleToString(g_dashMinusDi, 2) : "-", InpDownColor);
         TCell("สภาวะตลาด", fg, "ไซด์เวย์ = ราคาแกว่งไม่มีทิศ สัญญาณหลอกเยอะ");
         TCell(phase, phaseClr);
         TCell("ฝั่งที่แรงกว่า", fg, "+DI > −DI = ขาขึ้น, −DI > +DI = ขาลง");
         TCell(side, side == "ขาขึ้น" ? InpUpColor : side == "ขาลง" ? InpDownColor : fg);
         TCell("Supertrend", fg, "ทิศของ Supertrend บนไทม์เฟรมนี้");
         TCell(g_dashDir < 0 ? "ขาขึ้น" : g_dashDir > 0 ? "ขาลง" : "-", g_dashDir < 0 ? InpUpColor : InpDownColor);
         TCell("สถานะ", fg, tipFilter);
         TCell(active ? "เข้าได้" : "รอ", active ? InpUpColor : InpDownColor);
        }
      TEnd("adx", InpAdxCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dadx_");

   //--- Multi-timeframe trend
   if(!hideAll && InpMtfMode != DASH_HIDDEN)
     {
      ENUM_TIMEFRAMES tfs[5] = {PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
      string tipScore = "คะแนน 0–100: ADX < " + DoubleToString(InpAdxRangeLevel, 0) + " = 50 · ขาขึ้น = 50 + ADX · ขาลง = 50 − ADX";
      if(InpMtfMode == DASH_COMPACT)
         TBegin(5);
      else
        {
         TBegin(3);
         TCell("ไทม์เฟรม", headClr, "เทรนด์ของไทม์เฟรมอื่นบนสินทรัพย์เดียวกัน");
         TCell("คะแนน", headClr, tipScore);
         TCell("ทิศทาง", headClr, "จาก Supertrend + ADX ของไทม์เฟรมนั้น (แท่งปัจจุบัน)");
        }
      for(int k = 0; k < 5; k++)
        {
         MqlRates r[];
         int d = 0;
         double adx = EMPTY_VALUE;
         int got = CopyRates(_Symbol, tfs[k], 0, 400, r);
         if(got > InpAtrPeriod + InpAdxLength + InpAdxSmoothing)
           {
            int dd[];
            RatesSupertrend(r, dd);
            d = dd[ArraySize(dd) - 1];
            adx = RatesAdxLast(r);
           }
         else
            Log(LOG_DETAIL, StringFormat("เทรนด์หลาย TF: ข้อมูล %s ยังไม่พร้อม (ได้ %d แท่ง)", TfName(tfs[k]), got));
         double sc = TrendScore(d, adx);
         int state = TrendState(d, adx);
         color sclr = state > 0 ? InpUpColor : state < 0 ? InpDownColor : fg;
         string arrow = state > 0 ? "▲" : state < 0 ? "▼" : "•";
         if(InpMtfMode == DASH_COMPACT)
            TCell(TfName(tfs[k]) + " " + arrow, sclr, TfName(tfs[k]) + ": " + ThState(state) + " (คะแนน " + DoubleToString(sc, 0) + ") · ▲ ขึ้น ▼ ลง • กลาง");
         else
           {
            TCell(TfName(tfs[k]), fg);
            TCell(DoubleToString(sc, 1), sclr, tipScore);
            TCell(ThState(state), sclr);
           }
        }
      TEnd("mtf", InpMtfCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dmtf_");

   //--- Trade history
   if(!hideAll && InpHistoryMode != DASH_HIDDEN)
     {
      int maxRows = InpHistoryMode == DASH_COMPACT ? 3 : 10;
      string tipOutcome = "TP1/TP2/TP3 = TP สูงสุดที่ไปถึง · →SL = ถึง TP แล้วกลับมาโดน SL · SL = โดน SL ก่อน TP1 · กลับทิศ = มีสัญญาณตรงข้ามก่อน";
      TBegin(5);
      TCell("#", headClr, "1 = ล่าสุด");
      TCell("ฝั่ง", headClr);
      TCell("ผล", headClr, tipOutcome);
      TCell("R", headClr, "ผลเป็นหน่วย R ถ้าปิดที่ TP สูงสุดที่ไปถึง · SL = −1R · กลับทิศ = R จริงตอนปิดแท่ง");
      TCell("โดน SL", headClr, "ใช่ = ราคาแตะ SL (ก่อนหรือหลังถึง TP)");
      int shown = 0;
      for(int k = g_eng.recCount - 1; k >= 0 && shown < maxRows; k--)
        {
         if(!g_eng.recs[k].histDone)
            continue;
         shown++;
         string oc = g_eng.recs[k].outcome == "REV" ? "กลับทิศ" : g_eng.recs[k].outcome;
         TCell(IntegerToString(shown), fg);
         TCell(g_eng.recs[k].side > 0 ? "ซื้อ" : "ขาย", g_eng.recs[k].side > 0 ? InpUpColor : InpDownColor);
         TCell(oc, g_eng.recs[k].outcome == "SL" ? InpDownColor : g_eng.recs[k].outcome == "REV" ? fg : InpUpColor, tipOutcome);
         TCell(DoubleToString(g_eng.recs[k].histR, 2) + "R", g_eng.recs[k].histR >= 0.0 ? InpUpColor : InpDownColor);
         TCell(g_eng.recs[k].slHit ? "ใช่" : "ไม่", g_eng.recs[k].slHit ? InpDownColor : InpUpColor);
        }
      TEnd("hist", InpHistoryCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dhist_");
   CheckLayout();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Indicator events                                                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFactor <= 0.0 || InpAtrPeriod < 1 || InpSlAtrMult <= 0.0 || InpTp1R <= 0.0 || InpTp2R <= 0.0 || InpTp3R <= 0.0
      || InpAdxLength < 1 || InpAdxSmoothing < 1 || InpPivotLength < 1 || InpKeyLevelsCount < 1)
     {
      Print("[ST67][IND] ค่าที่ตั้งไม่ถูกต้อง (ต้องมากกว่า 0)");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_logTag = "[ST67][IND " + TfName(PERIOD_CURRENT) + (InpDrawObjects ? " แสดงผล" : " ใช้เทรด") + "]";
   SetIndexBuffer(0, B_stUp, INDICATOR_DATA);
   SetIndexBuffer(1, B_stDn, INDICATOR_DATA);
   SetIndexBuffer(2, B_fillClose, INDICATOR_DATA);
   SetIndexBuffer(3, B_st, INDICATOR_DATA);
   SetIndexBuffer(4, B_cO, INDICATOR_DATA);
   SetIndexBuffer(5, B_cH, INDICATOR_DATA);
   SetIndexBuffer(6, B_cL, INDICATOR_DATA);
   SetIndexBuffer(7, B_cC, INDICATOR_DATA);
   SetIndexBuffer(8, B_cClr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(9, B_buy, INDICATOR_DATA);
   SetIndexBuffer(10, B_sell, INDICATOR_DATA);
   SetIndexBuffer(11, B_ema200, INDICATOR_DATA);
   SetIndexBuffer(12, B_emaRe, INDICATOR_DATA);
   SetIndexBuffer(13, B_sig, INDICATOR_DATA);
   SetIndexBuffer(14, B_entry, INDICATOR_DATA);
   SetIndexBuffer(15, B_sl, INDICATOR_DATA);
   SetIndexBuffer(16, B_tp1, INDICATOR_DATA);
   SetIndexBuffer(17, B_tp2, INDICATOR_DATA);
   SetIndexBuffer(18, B_tp3, INDICATOR_DATA);
   SetIndexBuffer(19, B_dir, INDICATOR_DATA);
   SetIndexBuffer(20, B_atr, INDICATOR_DATA);
   SetIndexBuffer(21, B_adx, INDICATOR_DATA);
   for(int p = 0; p < 17; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   color bg = ChartBg();
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpUpColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpDownColor);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 0, Blend(InpUpColor, bg, 0.22));
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 1, Blend(InpDownColor, bg, 0.22));
   if(InpShowCandleColors)
     {
      PlotIndexSetInteger(3, PLOT_LINE_COLOR, 0, InpCandleUpColor);
      PlotIndexSetInteger(3, PLOT_LINE_COLOR, 1, InpCandleDownColor);
     }
   else
     {
      PlotIndexSetInteger(3, PLOT_LINE_COLOR, 0, (color)ChartGetInteger(0, CHART_COLOR_CANDLE_BULL));
      PlotIndexSetInteger(3, PLOT_LINE_COLOR, 1, (color)ChartGetInteger(0, CHART_COLOR_CANDLE_BEAR));
     }
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, InpUpColor);
   PlotIndexSetInteger(5, PLOT_LINE_COLOR, InpDownColor);
   PlotIndexSetInteger(7, PLOT_LINE_COLOR, InpEntryColor);
   PlotIndexSetInteger(4, PLOT_ARROW, 233);
   PlotIndexSetInteger(5, PLOT_ARROW, 234);
   PlotIndexSetInteger(4, PLOT_ARROW_SHIFT, 14);
   PlotIndexSetInteger(5, PLOT_ARROW_SHIFT, -14);
   if(!InpShowTrendLine)
     {
      PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   if(!InpShowFill)
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpShowCandleColors && !InpShowFill)
      PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpShowSignals)
     {
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   if(!InpUseEma200Filter)
      PlotIndexSetInteger(6, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpReentryEma && !InpReentryEmaFast)
      PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_NONE);

   g_eng.Init((ENUM_TIMEFRAMES)_Period);
   if(InpHtfFilterTf != PERIOD_CURRENT && !g_eng.htfOn)
      Log(LOG_NORMAL, "ไม่ใช้ตัวกรอง TF ใหญ่ เพราะ " + TfName(InpHtfFilterTf) + " ไม่ใหญ่กว่า " + TfName(PERIOD_CURRENT));
   for(int k = 0; k < 5; k++)
     {
      g_tfLast[k] = 0;
      g_tfOk[k] = false;
      g_tfSignals[k] = 0;
      g_tfWins[k] = 0;
      g_tfLosses[k] = 0;
      g_tfSumR[k] = 0.0;
     }
   MathSrand((uint)GetTickCount());
   g_prefix = "STI" + IntegerToString(MathRand()) + "_";
   IndicatorSetString(INDICATOR_SHORTNAME, "ST TP/SL v" + IND_VERSION + " " + TfName(PERIOD_CURRENT));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   Log(LOG_NORMAL, StringFormat("เริ่ม v%s %s · Factor %.2f ATR %d SL×%.2f TP %.1f/%.1f/%.1fR · ADX กรอง %s · TF ใหญ่ %s · EMA200 %s · เบรก %s · เข้าซ้ำ %s/%s/%s",
                                IND_VERSION, _Symbol, InpFactor, InpAtrPeriod, InpSlAtrMult, InpTp1R, InpTp2R, InpTp3R,
                                InpUseAdxFilter ? "เปิด" : "ปิด", g_eng.htfOn ? TfName(InpHtfFilterTf) : "ปิด", InpUseEma200Filter ? "เปิด" : "ปิด",
                                InpBreakoutSignals ? "เปิด" : "ปิด", InpReentrySt ? "เปิด" : "ปิด", InpReentryEma ? "เปิด" : "ปิด", InpReentryEmaFast ? "เปิด" : "ปิด"));
   if(InpDrawObjects)
      EventSetTimer(10);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

void OnTimer()
  {
   if(!g_haveData || !InpDrawObjects)
      return;
   if(!InpHideAllDashboards && InpTfStatsMode != DASH_HIDDEN && (long)TimeCurrent() - (long)g_tfComputed >= 60)
      ComputeTfTable(false);
   DrawDashboards();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int minBars = MathMax(InpAtrPeriod, InpAdxLength + InpAdxSmoothing) + 2 * InpPivotLength + 5;
   if(rates_total < minBars)
     {
      LogOnce(LOG_NORMAL, "fewbars", StringFormat("แท่งบนกราฟยังน้อยเกินไป (%d < %d) รอข้อมูล", rates_total, minBars));
      return 0;
     }
   bool full = prev_calculated == 0 || prev_calculated > rates_total;
   ulong t0 = GetMicrosecondCount();
   int start;
   if(full)
     {
      int first = MathMax(0, rates_total - MathMax(InpMaxBars, 300));
      g_eng.Reset(rates_total, first);
      ObjectsDeleteAll(0, g_prefix);
      for(int i = 0; i < first; i++)
        {
         B_stUp[i] = EMPTY_VALUE;
         B_stDn[i] = EMPTY_VALUE;
         B_fillClose[i] = EMPTY_VALUE;
         B_st[i] = EMPTY_VALUE;
         B_cO[i] = EMPTY_VALUE;
         B_cH[i] = EMPTY_VALUE;
         B_cL[i] = EMPTY_VALUE;
         B_cC[i] = EMPTY_VALUE;
         B_cClr[i] = 0.0;
         B_buy[i] = EMPTY_VALUE;
         B_sell[i] = EMPTY_VALUE;
         B_ema200[i] = EMPTY_VALUE;
         B_emaRe[i] = EMPTY_VALUE;
         B_sig[i] = 0.0;
         B_entry[i] = EMPTY_VALUE;
         B_sl[i] = EMPTY_VALUE;
         B_tp1[i] = EMPTY_VALUE;
         B_tp2[i] = EMPTY_VALUE;
         B_tp3[i] = EMPTY_VALUE;
         B_dir[i] = 0.0;
         B_atr[i] = EMPTY_VALUE;
         B_adx[i] = EMPTY_VALUE;
        }
      start = first;
     }
   else
     {
      g_eng.Resize(rates_total);
      start = prev_calculated - 1;
     }

   bool newClosed = rates_total - 2 > g_eng.lastClosed;
   //--- The higher-timeframe series must include the candles that closed since the last call.
   if(g_eng.htfOn && (full || newClosed) && !g_eng.LoadHtf(time[g_eng.first]))
      return full ? 0 : prev_calculated;

   for(int i = start; i < rates_total; i++)
     {
      g_eng.Step(i, high, low, close);
      double s = g_eng.st[i];
      int d = (int)g_eng.dir[i];
      B_st[i] = s;
      B_dir[i] = d;
      B_atr[i] = g_eng.atr[i];
      B_adx[i] = g_eng.adx[i];
      B_ema200[i] = g_eng.ema200[i];
      B_emaRe[i] = g_eng.emaRe[i];
      B_fillClose[i] = s == EMPTY_VALUE ? EMPTY_VALUE : close[i];
      B_stUp[i] = (InpShowTrendLine && d < 0) ? s : EMPTY_VALUE;
      B_stDn[i] = (InpShowTrendLine && d > 0) ? s : EMPTY_VALUE;
      if(InpShowCandleColors || InpShowFill)
        {
         B_cO[i] = open[i];
         B_cH[i] = high[i];
         B_cL[i] = low[i];
         B_cC[i] = close[i];
         if(InpShowCandleColors && d != 0)
            B_cClr[i] = d < 0 ? 0.0 : 1.0;
         else
            B_cClr[i] = close[i] >= open[i] ? 0.0 : 1.0;
        }
      else
        {
         B_cO[i] = EMPTY_VALUE;
         B_cH[i] = EMPTY_VALUE;
         B_cL[i] = EMPTY_VALUE;
         B_cC[i] = EMPTY_VALUE;
         B_cClr[i] = 0.0;
        }
      //--- Signal outputs: set below for closed candles only.
      B_sig[i] = 0.0;
      B_buy[i] = EMPTY_VALUE;
      B_sell[i] = EMPTY_VALUE;
      B_entry[i] = EMPTY_VALUE;
      B_sl[i] = EMPTY_VALUE;
      B_tp1[i] = EMPTY_VALUE;
      B_tp2[i] = EMPTY_VALUE;
      B_tp3[i] = EMPTY_VALUE;
     }

   int signalsNow = 0;
   BarEvents ev;
   for(int i = g_eng.lastClosed + 1; i <= rates_total - 2; i++)
     {
      g_eng.Closed(i, time, high, low, close, ev);
      B_sig[i] = ev.sell ? -1.0 : ev.buy ? 1.0 : 0.0;
      if(g_eng.entry != EMPTY_VALUE)
        {
         B_entry[i] = g_eng.entry;
         B_sl[i] = g_eng.sl;
         B_tp1[i] = g_eng.tp1;
         B_tp2[i] = g_eng.tp2;
         B_tp3[i] = g_eng.tp3;
        }
      if(InpShowSignals)
        {
         B_buy[i] = ev.buy ? low[i] : EMPTY_VALUE;
         B_sell[i] = ev.sell ? high[i] : EMPTY_VALUE;
        }
      if(ev.buy || ev.sell)
         signalsNow++;
      if(InpDrawObjects && i >= rates_total - InpObjectBars)
         DrawBarEvents(i, time, high, low, close, ev);
      if(!full && i == rates_total - 2)
        {
         Log(LOG_DETAIL, StringFormat("แท่ง %s ปิด: ทิศ %d ป้าย %s ATR %s ADX %s", TimeToString(time[i]), (int)g_eng.dir[i],
                                      ev.sell ? "SELL" : ev.buy ? "BUY" : "-", Fmt(g_eng.atr[i]),
                                      g_eng.adx[i] == EMPTY_VALUE ? "-" : DoubleToString(g_eng.adx[i], 1)));
         //--- Alerts (live candles only, not while loading history)
         string head = _Symbol + " [" + TfName(PERIOD_CURRENT) + "]";
         if(InpAlertOnTpSl)
            for(int k = 2; k >= 0; k--)
               if(ev.tpHit[k])
                 {
                  Notify("✅ ถึง TP" + IntegerToString(k + 1) + " " + head + "\nราคา: " + Fmt(ev.tpPrice[k]));
                  break;
                 }
         if(InpAlertOnTpSl && ev.slHit)
            Notify("⛔ โดน SL " + head + "\nSL: " + Fmt(ev.slPrice));
         if(InpAlertOnSignal && (ev.buy || ev.sell))
            Notify((ev.sell ? "🔴 SELL (ขาย) " : "🟢 BUY (ซื้อ) ") + head
                   + "\nเข้า: " + Fmt(g_eng.entry)
                   + "\nSL: " + Fmt(g_eng.sl) + " (ระยะ " + Fmt(MathAbs(g_eng.entry - g_eng.sl)) + ")"
                   + "\nTP1: " + Fmt(g_eng.tp1) + "\nTP2: " + Fmt(g_eng.tp2) + "\nTP3: " + Fmt(g_eng.tp3));
        }
     }

   int last = rates_total - 1;
   g_dashAdx = g_eng.adx[last];
   g_dashDir = (int)g_eng.dir[last];
   g_dashPlusDi = g_eng.PlusDi(last);
   g_dashMinusDi = g_eng.MinusDi(last);
   g_dashNow = time[last];
   g_haveData = true;

   if(full)
      Log(LOG_NORMAL, StringFormat("คำนวณใหม่ทั้งหมด %d แท่ง (%s ถึง %s) สัญญาณ %d ครั้ง ใช้เวลา %.0f ms",
                                   rates_total - g_eng.first, TimeToString(time[g_eng.first]), TimeToString(time[last]),
                                   signalsNow, (GetMicrosecondCount() - t0) / 1000.0));
   if(InpDrawObjects && (full || newClosed))
     {
      DrawTradeObjects(rates_total, time);
      DrawPatternObjects(rates_total, time);
      if(!InpHideAllDashboards && InpTfStatsMode != DASH_HIDDEN && (full || (long)TimeCurrent() - (long)g_tfComputed >= 60))
         ComputeTfTable(full);
      DrawDashboards();
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
