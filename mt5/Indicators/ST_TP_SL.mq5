//+------------------------------------------------------------------+
//|                                                     ST_TP_SL.mq5 |
//|  MT5 port of indicators/ST_with_TP_SL.pine (TradingView).        |
//|                                                                  |
//|  - Supertrend line, BUY/SELL on closed candles (no repaint)      |
//|  - Entry / SL / TP1-TP3 lines, zones, price labels, TP marks     |
//|  - Optional filters: ADX, higher-timeframe trend, EMA 200        |
//|  - Optional signals: trend-line/channel breakout, re-entry       |
//|    after TP3 (Supertrend touch, EMA cross, fast EMA touch)       |
//|  - Dashboards: statistics, ADX, multi-timeframe, trade history   |
//|                                                                  |
//|  The EA (Experts/ST_TP_SL_EA.mq5) embeds this indicator and      |
//|  trades its signal buffers, so the chart labels and the orders   |
//|  always come from the same code.                                 |
//|                                                                  |
//|  Buffers read by the EA (index = buffer number):                 |
//|   3 Supertrend value   13 signal (1 BUY, -1 SELL, 0)             |
//|  14 entry  15 SL  16 TP1  17 TP2  18 TP3                         |
//|  19 direction (-1 up, 1 down)  20 ATR  21 ADX                    |
//|  Keep the input order in sync with the EA (mt5/tools/            |
//|  check_inputs.py verifies it).                                   |
//+------------------------------------------------------------------+
#property copyright   "Trading-signals67"
#property link        "https://github.com/maung5678/Trading-signals67"
#property version     "1.10"
#property description "Supertrend TP/SL v1.10: สัญญาณ BUY/SELL บนแท่งที่ปิดแล้ว พร้อม Entry, SL, TP1–TP3 และแดชบอร์ด"
#property indicator_chart_window
#property indicator_buffers 29
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

#define IND_VERSION "1.10"

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
input ENUM_DASH_MODE    InpStatsMode         = DASH_COMPACT;       // สถิติชนะ/แพ้
input ENUM_STATS_PERIOD InpStatsPeriod       = STATS_ALL;          // ช่วงเวลาของสถิติ
input ENUM_BASE_CORNER  InpStatsCorner       = CORNER_RIGHT_UPPER; // ตำแหน่งสถิติ
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

//--- Buffers
double B_stUp[], B_stDn[], B_fillClose[], B_st[];
double B_cO[], B_cH[], B_cL[], B_cC[], B_cClr[];
double B_buy[], B_sell[], B_ema200[], B_emaRe[];
double B_sig[], B_entry[], B_sl[], B_tp1[], B_tp2[], B_tp3[], B_dir[], B_atr[], B_adx[];
double B_upper[], B_lower[], B_trur[], B_plusS[], B_minusS[], B_dx[], B_adxRaw[];

//--- One virtual trade per signal (same model as the TradingView statistics).
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

TradeRec g_recs[];
int      g_recCount = 0;

//--- State
string   g_prefix = "";
int      g_first = 0;          // first calculated bar
int      g_lastClosed = -1;    // last closed bar run through the trade logic
int      g_tDir = 0;
double   g_entry = EMPTY_VALUE, g_sl = EMPTY_VALUE, g_tp1 = EMPTY_VALUE, g_tp2 = EMPTY_VALUE, g_tp3 = EMPTY_VALUE;
int      g_tradeBar = -1;
bool     g_tp1Reached = false, g_tp2Reached = false, g_tp3Reached = false;
bool     g_resolved = false, g_histRecorded = false;
bool     g_reLongArmed = false, g_reShortArmed = false, g_emaLongPull = false, g_emaShortPull = false;
// Pivots (bar indexes, -1 = none)
double   g_prevSupP = EMPTY_VALUE, g_lastSupP = EMPTY_VALUE, g_prevResP = EMPTY_VALUE, g_lastResP = EMPTY_VALUE;
int      g_prevSupB = -1, g_lastSupB = -1, g_prevResB = -1, g_lastResB = -1;
// Key levels
double   g_kSupPrice[], g_kResPrice[];
int      g_kSupBar[], g_kResBar[];
// Higher-timeframe filter
bool     g_htfOn = false;
datetime g_htfTime[];
int      g_htfDir[];
// Values for the dashboards (updated in OnCalculate, also used by OnTimer)
double   g_dashAdx = EMPTY_VALUE, g_dashPlusDi = EMPTY_VALUE, g_dashMinusDi = EMPTY_VALUE;
int      g_dashDir = 0;
datetime g_dashNow = 0;
bool     g_haveData = false;

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
   if(InpAlertPopup)
      Alert(msg);
   if(InpAlertPush && !MQLInfoInteger(MQL_TESTER))
      SendNotification(StringSubstr(msg, 0, 255));
  }

//--- Chart objects
void ObjText(const string name, const datetime t, const double price, const string text, const color clr,
             const int size, const ENUM_ANCHOR_POINT anchor, const string tip = "")
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
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
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
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
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
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
//| Indicator math on MqlRates arrays (index 0 = oldest).            |
//| Used for the higher-timeframe filter and the MTF dashboard.      |
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
      else if(stPrev == upperPrev)
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

//--- Higher-timeframe direction of the last HTF candle closed at `t` (no repaint).
bool LoadHtf(const datetime fromTime)
  {
   MqlRates h[];
   int secs = PeriodSeconds(InpHtfFilterTf);
   datetime from = (datetime)((long)fromTime - (long)secs * (InpAtrPeriod * 20 + 50));
   datetime to = (datetime)((long)TimeCurrent() + secs);
   int got = CopyRates(_Symbol, InpHtfFilterTf, from, to, h);
   if(got < InpAtrPeriod + 3)
      return false;
   int dir[];
   RatesSupertrend(h, dir);
   ArrayResize(g_htfTime, got);
   ArrayResize(g_htfDir, got);
   for(int j = 0; j < got; j++)
     {
      g_htfTime[j] = h[j].time;
      g_htfDir[j] = dir[j];
     }
   return true;
  }

int HtfDirAt(const datetime barOpen)
  {
   int n = ArraySize(g_htfTime);
   int secs = PeriodSeconds(InpHtfFilterTf);
   int lo = 0, hi = n - 1, found = -1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if((long)g_htfTime[mid] + secs <= (long)barOpen)
        {
         found = mid;
         lo = mid + 1;
        }
      else
         hi = mid - 1;
     }
   return found < 0 ? 0 : g_htfDir[found];
  }

//+------------------------------------------------------------------+
//| Per-bar calculation on the chart (incremental, index 0 = oldest) |
//+------------------------------------------------------------------+
double TrAt(const int i, const double &h[], const double &l[], const double &c[])
  {
   if(i <= g_first)
      return h[i] - l[i];
   return MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - c[i - 1]), MathAbs(l[i] - c[i - 1])));
  }

double PlusDmAt(const int i, const double &h[], const double &l[])
  {
   double up = h[i] - h[i - 1], down = l[i - 1] - l[i];
   return (up > down && up > 0.0) ? up : 0.0;
  }

double MinusDmAt(const int i, const double &h[], const double &l[])
  {
   double up = h[i] - h[i - 1], down = l[i - 1] - l[i];
   return (down > up && down > 0.0) ? down : 0.0;
  }

// TradingView ta.ema: seeded with an SMA of the first `len` closes.
double EmaAt(const int i, const int len, const double &c[], const double &buf[])
  {
   int k = i - g_first;
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

void StepBar(const int i, const double &o[], const double &h[], const double &l[], const double &c[])
  {
   int k = i - g_first;
   int p = InpAtrPeriod;
   //--- ATR (RMA)
   double atr = EMPTY_VALUE;
   if(k == p - 1)
     {
      double s = 0.0;
      for(int j = i - p + 1; j <= i; j++)
         s += TrAt(j, h, l, c);
      atr = s / p;
     }
   else
      if(k >= p && B_atr[i - 1] != EMPTY_VALUE)
         atr = (B_atr[i - 1] * (p - 1) + TrAt(i, h, l, c)) / p;
   B_atr[i] = atr;

   //--- Supertrend
   int d = 0;
   double st = EMPTY_VALUE;
   B_upper[i] = EMPTY_VALUE;
   B_lower[i] = EMPTY_VALUE;
   if(atr != EMPTY_VALUE)
     {
      double upPrev = (k > 0 && B_upper[i - 1] != EMPTY_VALUE) ? B_upper[i - 1] : 0.0;
      double loPrev = (k > 0 && B_lower[i - 1] != EMPTY_VALUE) ? B_lower[i - 1] : 0.0;
      double src = (h[i] + l[i]) / 2.0;
      double upper = src + InpFactor * atr;
      double lower = src - InpFactor * atr;
      double prevClose = k > 0 ? c[i - 1] : c[i];
      lower = (lower > loPrev || prevClose < loPrev) ? lower : loPrev;
      upper = (upper < upPrev || prevClose > upPrev) ? upper : upPrev;
      if(k == 0 || B_atr[i - 1] == EMPTY_VALUE)
         d = 1;
      else
         if(B_st[i - 1] == B_upper[i - 1])
            d = c[i] > upper ? -1 : 1;
         else
            d = c[i] < lower ? 1 : -1;
      st = d == -1 ? lower : upper;
      B_upper[i] = upper;
      B_lower[i] = lower;
     }
   B_st[i] = st;
   B_dir[i] = d;
   B_fillClose[i] = st == EMPTY_VALUE ? EMPTY_VALUE : c[i];
   B_stUp[i] = (InpShowTrendLine && d < 0) ? st : EMPTY_VALUE;
   B_stDn[i] = (InpShowTrendLine && d > 0) ? st : EMPTY_VALUE;

   //--- Candles (also redrawn when only the fill is on, so the fill does not hide them)
   if(InpShowCandleColors || InpShowFill)
     {
      B_cO[i] = o[i];
      B_cH[i] = h[i];
      B_cL[i] = l[i];
      B_cC[i] = c[i];
      if(InpShowCandleColors)
         B_cClr[i] = d < 0 ? 0.0 : d > 0 ? 1.0 : (c[i] >= o[i] ? 0.0 : 1.0);
      else
         B_cClr[i] = c[i] >= o[i] ? 0.0 : 1.0;
     }
   else
     {
      B_cO[i] = EMPTY_VALUE;
      B_cH[i] = EMPTY_VALUE;
      B_cL[i] = EMPTY_VALUE;
      B_cC[i] = EMPTY_VALUE;
      B_cClr[i] = 0.0;
     }

   //--- ADX (ta.dmi)
   int L = InpAdxLength, S = InpAdxSmoothing;
   double trur = EMPTY_VALUE, ps = EMPTY_VALUE, ms = EMPTY_VALUE;
   if(k == L - 1)
     {
      double s = 0.0;
      for(int j = i - L + 1; j <= i; j++)
         s += TrAt(j, h, l, c);
      trur = s / L;
     }
   else
      if(k >= L && B_trur[i - 1] != EMPTY_VALUE)
         trur = (B_trur[i - 1] * (L - 1) + TrAt(i, h, l, c)) / L;
   if(k == L)
     {
      double sp = 0.0, sm = 0.0;
      for(int j = i - L + 1; j <= i; j++)
        {
         sp += PlusDmAt(j, h, l);
         sm += MinusDmAt(j, h, l);
        }
      ps = sp / L;
      ms = sm / L;
     }
   else
      if(k > L && B_plusS[i - 1] != EMPTY_VALUE)
        {
         ps = (B_plusS[i - 1] * (L - 1) + PlusDmAt(i, h, l)) / L;
         ms = (B_minusS[i - 1] * (L - 1) + MinusDmAt(i, h, l)) / L;
        }
   B_trur[i] = trur;
   B_plusS[i] = ps;
   B_minusS[i] = ms;
   double dx = EMPTY_VALUE;
   if(trur != EMPTY_VALUE && ps != EMPTY_VALUE)
     {
      if(trur == 0.0)
         dx = 0.0;
      else
        {
         double pdi = 100.0 * ps / trur, mdi = 100.0 * ms / trur;
         double sum = pdi + mdi;
         dx = MathAbs(pdi - mdi) / (sum != 0.0 ? sum : 1.0);
        }
     }
   B_dx[i] = dx;
   double adxRaw = EMPTY_VALUE;
   if(k == L + S - 1)
     {
      double s = 0.0;
      bool ok = true;
      for(int j = i - S + 1; j <= i; j++)
        {
         if(B_dx[j] == EMPTY_VALUE)
            ok = false;
         else
            s += B_dx[j];
        }
      if(ok)
         adxRaw = s / S;
     }
   else
      if(k > L + S - 1 && B_adxRaw[i - 1] != EMPTY_VALUE)
         adxRaw = dx == EMPTY_VALUE ? B_adxRaw[i - 1] : (B_adxRaw[i - 1] * (S - 1) + dx) / S;
   B_adxRaw[i] = adxRaw;
   B_adx[i] = adxRaw == EMPTY_VALUE ? EMPTY_VALUE : 100.0 * adxRaw;

   //--- EMAs
   B_ema200[i] = EmaAt(i, 200, c, B_ema200);
   B_emaRe[i] = EmaAt(i, MathMax(1, InpReentryEmaLength), c, B_emaRe);

   //--- Signal outputs: filled by ProcessClosedBar on closed candles only.
   B_sig[i] = 0.0;
   B_buy[i] = EMPTY_VALUE;
   B_sell[i] = EMPTY_VALUE;
   B_entry[i] = EMPTY_VALUE;
   B_sl[i] = EMPTY_VALUE;
   B_tp1[i] = EMPTY_VALUE;
   B_tp2[i] = EMPTY_VALUE;
   B_tp3[i] = EMPTY_VALUE;
  }

//+------------------------------------------------------------------+
//| Virtual trade bookkeeping (statistics + history table)           |
//+------------------------------------------------------------------+
void RecResolve(const double r, const bool win)
  {
   if(g_recCount == 0)
      return;
   int n = g_recCount - 1;
   g_recs[n].resolved = true;
   g_recs[n].win = win;
   g_recs[n].statR = r;
  }

void RecHistory(const string outcome, const double r, const bool slHit)
  {
   if(g_histRecorded || g_recCount == 0)
      return;
   int n = g_recCount - 1;
   g_recs[n].histDone = true;
   g_recs[n].outcome = outcome;
   g_recs[n].histR = r;
   g_recs[n].slHit = slHit;
   g_histRecorded = true;
  }

void NewTrade(const int side, const int i, const datetime t, const double c, const double atr)
  {
   g_entry = c;
   double risk = atr * InpSlAtrMult;
   g_sl = c - side * risk;
   g_tp1 = c + side * risk * InpTp1R;
   g_tp2 = c + side * risk * InpTp2R;
   g_tp3 = c + side * risk * InpTp3R;
   g_tDir = side;
   g_tradeBar = i;
   g_tp1Reached = false;
   g_tp2Reached = false;
   g_tp3Reached = false;
   g_resolved = false;
   g_histRecorded = false;
   g_reLongArmed = false;
   g_reShortArmed = false;
   g_emaLongPull = false;
   g_emaShortPull = false;
   if(g_recCount >= ArraySize(g_recs))
      ArrayResize(g_recs, g_recCount + 256);
   g_recs[g_recCount].time = t;
   g_recs[g_recCount].side = side;
   g_recs[g_recCount].resolved = false;
   g_recs[g_recCount].win = false;
   g_recs[g_recCount].statR = 0.0;
   g_recs[g_recCount].histDone = false;
   g_recs[g_recCount].outcome = "";
   g_recs[g_recCount].histR = 0.0;
   g_recs[g_recCount].slHit = false;
   g_recCount++;
  }

string MaxTpText()
  {
   return g_tp3Reached ? "TP3" : g_tp2Reached ? "TP2" : "TP1";
  }

double MaxTpR()
  {
   return g_tp3Reached ? InpTp3R : g_tp2Reached ? InpTp2R : InpTp1R;
  }

//--- Pivot confirmed on bar i (pivot bar = i - L). Left side strictly lower/higher.
double PivotHighAt(const int i, const double &h[])
  {
   int L = InpPivotLength, p = i - L;
   if(p - L < g_first)
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

double PivotLowAt(const int i, const double &l[])
  {
   int L = InpPivotLength, p = i - L;
   if(p - L < g_first)
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
double LineAt(const int b1, const double p1, const int b2, const double p2, const int x)
  {
   if(b1 < 0 || b2 < 0 || b1 == b2 || p1 == EMPTY_VALUE || p2 == EMPTY_VALUE)
      return EMPTY_VALUE;
   return p1 + (p2 - p1) / (b2 - b1) * (x - b1);
  }

// Upper / lower breakout boundaries at bar x (same construction as the TradingView script).
void BreakoutBounds(const int x, double &upper, double &lower)
  {
   double supNow = LineAt(g_prevSupB, g_prevSupP, g_lastSupB, g_lastSupP, x);
   double resNow = LineAt(g_prevResB, g_prevResP, g_lastResB, g_lastResP, x);
   double supAtRes = g_lastResB >= 0 ? LineAt(g_prevSupB, g_prevSupP, g_lastSupB, g_lastSupP, g_lastResB) : EMPTY_VALUE;
   double resAtSup = g_lastSupB >= 0 ? LineAt(g_prevResB, g_prevResP, g_lastResB, g_lastResP, g_lastSupB) : EMPTY_VALUE;
   double upWidth = (supAtRes != EMPTY_VALUE && g_lastResP != EMPTY_VALUE) ? g_lastResP - supAtRes : EMPTY_VALUE;
   double downWidth = (resAtSup != EMPTY_VALUE && g_lastSupP != EMPTY_VALUE) ? resAtSup - g_lastSupP : EMPTY_VALUE;
   bool upValid = upWidth != EMPTY_VALUE && upWidth > 0.0 && supNow != EMPTY_VALUE;
   bool downValid = downWidth != EMPTY_VALUE && downWidth > 0.0 && resNow != EMPTY_VALUE;
   upper = upValid ? supNow + upWidth : resNow;
   lower = downValid ? resNow - downWidth : supNow;
  }

void AddKeyLevel(double &prices[], int &bars[], const double price, const int bar, const double tol)
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
   // newest first
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

//+------------------------------------------------------------------+
//| Signals and the virtual trade on a closed candle                 |
//+------------------------------------------------------------------+
void ProcessClosedBar(const int i, const int ratesTotal, const datetime &time[], const double &h[],
                      const double &l[], const double &c[], const bool live)
  {
   //--- Pivots confirmed on this bar
   int L = InpPivotLength;
   double pivHigh = PivotHighAt(i, h);
   double pivLow = PivotLowAt(i, l);
   if(pivLow != EMPTY_VALUE)
     {
      g_prevSupP = g_lastSupP;
      g_prevSupB = g_lastSupB;
      g_lastSupP = pivLow;
      g_lastSupB = i - L;
     }
   if(pivHigh != EMPTY_VALUE)
     {
      g_prevResP = g_lastResP;
      g_prevResB = g_lastResB;
      g_lastResP = pivHigh;
      g_lastResB = i - L;
     }

   int dir = (int)B_dir[i];
   int dirPrev = (int)B_dir[i - 1];
   bool up = dir < 0, dn = dir > 0;
   double st = B_st[i];
   double ema = B_emaRe[i], emaPrev = B_emaRe[i - 1];
   bool emaOk = ema != EMPTY_VALUE && emaPrev != EMPTY_VALUE;
   bool emaCrossUp = emaOk && c[i] > ema && c[i - 1] <= emaPrev;
   bool emaCrossDown = emaOk && c[i] < ema && c[i - 1] >= emaPrev;

   bool stBuy = dir < 0 && dirPrev > 0;
   bool stSell = dir > 0 && dirPrev < 0;
   bool reBuy = InpReentrySt && g_reLongArmed && up && st != EMPTY_VALUE && l[i] <= st && c[i] > st;
   bool reSell = InpReentrySt && g_reShortArmed && dn && st != EMPTY_VALUE && h[i] >= st && c[i] < st;
   bool emaReBuy = InpReentryEma && g_reLongArmed && up && g_emaLongPull && emaCrossUp;
   bool emaReSell = InpReentryEma && g_reShortArmed && dn && g_emaShortPull && emaCrossDown;
   bool fastBuy = InpReentryEmaFast && g_reLongArmed && up && ema != EMPTY_VALUE && l[i] <= ema && c[i] > ema;
   bool fastSell = InpReentryEmaFast && g_reShortArmed && dn && ema != EMPTY_VALUE && h[i] >= ema && c[i] < ema;
   bool boBuy = false, boSell = false;
   if(InpBreakoutSignals)
     {
      double upNow, loNow, upPrev, loPrev;
      BreakoutBounds(i, upNow, loNow);
      BreakoutBounds(i - 1, upPrev, loPrev);
      boBuy = upNow != EMPTY_VALUE && upPrev != EMPTY_VALUE && c[i] > upNow && c[i - 1] <= upPrev;
      boSell = loNow != EMPTY_VALUE && loPrev != EMPTY_VALUE && c[i] < loNow && c[i - 1] >= loPrev;
     }

   bool adxOk = !InpUseAdxFilter || (B_adx[i] != EMPTY_VALUE && B_adx[i] > InpAdxSignalMin);
   bool emaLongOk = !InpUseEma200Filter || (B_ema200[i] != EMPTY_VALUE && c[i] > B_ema200[i]);
   bool emaShortOk = !InpUseEma200Filter || (B_ema200[i] != EMPTY_VALUE && c[i] < B_ema200[i]);
   bool htfLongOk = true, htfShortOk = true;
   if(g_htfOn)
     {
      int hd = HtfDirAt(time[i]);
      htfLongOk = hd < 0;
      htfShortOk = hd > 0;
     }
   bool buy = (stBuy || boBuy || reBuy || emaReBuy || fastBuy) && adxOk && emaLongOk && htfLongOk;
   bool sell = (stSell || boSell || reSell || emaReSell || fastSell) && adxOk && emaShortOk && htfShortOk;
   if(InpReentryEma && g_reLongArmed && up && emaCrossDown)
      g_emaLongPull = true;
   if(InpReentryEma && g_reShortArmed && dn && emaCrossUp)
      g_emaShortPull = true;

   bool drawObjects = i >= ratesTotal - InpObjectBars;
   string evTp = "";
   double evTpPrice = 0.0;
   bool evSl = false;
   double evSlPrice = 0.0;

   //--- Open virtual trade: SL first, then TP1 (statistics model: whole trade closed at TP1 / SL / reversal)
   if(g_tDir != 0 && !g_resolved)
     {
      bool slHit = g_tDir == 1 ? l[i] <= g_sl : h[i] >= g_sl;
      bool tp1Hit = g_tDir == 1 ? h[i] >= g_tp1 : l[i] <= g_tp1;
      if(slHit)
        {
         evSl = true;
         evSlPrice = g_sl;
         RecResolve(-1.0, false);
         RecHistory("SL", -1.0, true);
         g_resolved = true;
         g_tDir = 0;
        }
      else
         if(tp1Hit)
           {
            RecResolve(InpTp1R, true);
            g_resolved = true;
           }
     }
   //--- After TP1 the trade runs toward TP2/TP3; back to the original SL ends it.
   if(g_tDir != 0 && g_tp1Reached)
     {
      bool slHit = g_tDir == 1 ? l[i] <= g_sl : h[i] >= g_sl;
      if(slHit)
        {
         evSl = true;
         evSlPrice = g_sl;
         RecHistory(MaxTpText() + "→SL", MaxTpR(), true);
         g_tDir = 0;
        }
     }
   if(g_tDir != 0)
     {
      bool isLong = g_tDir == 1;
      if(!g_tp1Reached && (isLong ? h[i] >= g_tp1 : l[i] <= g_tp1))
        {
         g_tp1Reached = true;
         evTp = "TP1";
         evTpPrice = g_tp1;
         if(InpShowTpMarks && drawObjects)
            ObjText(g_prefix + "tp1_" + IntegerToString(i), time[i], g_tp1, "✓ TP1", InpTp1Color, 7, isLong ? ANCHOR_UPPER : ANCHOR_LOWER);
        }
      if(!g_tp2Reached && (isLong ? h[i] >= g_tp2 : l[i] <= g_tp2))
        {
         g_tp2Reached = true;
         evTp = "TP2";
         evTpPrice = g_tp2;
         if(InpShowTpMarks && drawObjects)
            ObjText(g_prefix + "tp2_" + IntegerToString(i), time[i], g_tp2, "✓ TP2", InpTp2Color, 7, isLong ? ANCHOR_UPPER : ANCHOR_LOWER);
        }
      if(!g_tp3Reached && (isLong ? h[i] >= g_tp3 : l[i] <= g_tp3))
        {
         g_tp3Reached = true;
         evTp = "TP3";
         evTpPrice = g_tp3;
         if(isLong)
           {
            g_reLongArmed = true;
            g_emaLongPull = false;
           }
         else
           {
            g_reShortArmed = true;
            g_emaShortPull = false;
           }
         RecHistory("TP3", InpTp3R, false);
         if(InpShowTpMarks && drawObjects)
            ObjText(g_prefix + "tp3_" + IntegerToString(i), time[i], g_tp3, "✓ TP3", InpTp3Color, 7, isLong ? ANCHOR_UPPER : ANCHOR_LOWER);
        }
     }
   if(evSl && InpShowTpMarks && drawObjects)
      ObjText(g_prefix + "sl_" + IntegerToString(i), time[i], evSlPrice, "✗ SL", InpSlColor, 7, ANCHOR_CENTER);

   //--- A new signal while the previous trade is still open: close it at this candle's close.
   double risk = (g_entry != EMPTY_VALUE && g_sl != EMPTY_VALUE) ? MathAbs(g_entry - g_sl) : 0.0;
   double reversalR = (g_tDir != 0 && risk > 0.0) ? (c[i] - g_entry) * g_tDir / risk : 0.0;
   if((buy || sell) && g_tDir != 0 && !g_resolved)
     {
      RecResolve(reversalR, reversalR > 0.0);
      g_resolved = true;
     }
   if((buy || sell) && g_tDir != 0 && !g_histRecorded)
     {
      string outcome = g_tp3Reached ? "TP3" : g_tp2Reached ? "TP2" : g_tp1Reached ? "TP1" : "REV";
      double r = g_tp3Reached ? InpTp3R : g_tp2Reached ? InpTp2R : g_tp1Reached ? InpTp1R : reversalR;
      RecHistory(outcome, r, false);
     }

   //--- New trade levels
   if(buy && B_atr[i] != EMPTY_VALUE)
      NewTrade(1, i, time[i], c[i], B_atr[i]);
   if(sell && B_atr[i] != EMPTY_VALUE)
      NewTrade(-1, i, time[i], c[i], B_atr[i]);

   //--- Outputs for the EA and the arrows
   B_sig[i] = sell ? -1.0 : buy ? 1.0 : 0.0;
   if(g_entry != EMPTY_VALUE)
     {
      B_entry[i] = g_entry;
      B_sl[i] = g_sl;
      B_tp1[i] = g_tp1;
      B_tp2[i] = g_tp2;
      B_tp3[i] = g_tp3;
     }
   if(InpShowSignals)
     {
      B_buy[i] = buy ? l[i] : EMPTY_VALUE;
      B_sell[i] = sell ? h[i] : EMPTY_VALUE;
      if(drawObjects && buy)
         ObjText(g_prefix + "buy_" + IntegerToString(i), time[i], l[i], "BUY", InpUpColor, 7, ANCHOR_UPPER,
                 "BUY " + Fmt(c[i]) + " · " + TimeToString(time[i], TIME_DATE | TIME_MINUTES));
      if(drawObjects && sell)
         ObjText(g_prefix + "sell_" + IntegerToString(i), time[i], h[i], "SELL", InpDownColor, 7, ANCHOR_LOWER,
                 "SELL " + Fmt(c[i]) + " · " + TimeToString(time[i], TIME_DATE | TIME_MINUTES));
     }

   //--- Key levels (horizontal support / resistance)
   if(InpShowKeyLevels && B_atr[i] != EMPTY_VALUE)
     {
      double tol = B_atr[i] * InpKeyLevelTolAtr;
      if(pivLow != EMPTY_VALUE)
         AddKeyLevel(g_kSupPrice, g_kSupBar, pivLow, i - L, tol);
      if(pivHigh != EMPTY_VALUE)
         AddKeyLevel(g_kResPrice, g_kResBar, pivHigh, i - L, tol);
     }

   //--- Alerts (live candles only, not while loading history)
   if(live && i == ratesTotal - 2)
     {
      string head = _Symbol + " [" + TfName(PERIOD_CURRENT) + "]";
      if(InpAlertOnTpSl && evTp != "")
         Notify("✅ ถึง " + evTp + " " + head + "\nราคา: " + Fmt(evTpPrice));
      if(InpAlertOnTpSl && evSl)
         Notify("⛔ โดน SL " + head + "\nSL: " + Fmt(evSlPrice));
      if(InpAlertOnSignal && (buy || sell))
         Notify((sell ? "🔴 SELL (ขาย) " : "🟢 BUY (ซื้อ) ") + head
                + "\nเข้า: " + Fmt(g_entry)
                + "\nSL: " + Fmt(g_sl) + " (ระยะ " + Fmt(MathAbs(g_entry - g_sl)) + ")"
                + "\nTP1: " + Fmt(g_tp1) + "\nTP2: " + Fmt(g_tp2) + "\nTP3: " + Fmt(g_tp3));
     }
  }

//+------------------------------------------------------------------+
//| Drawing of the latest trade, trend lines and key levels          |
//+------------------------------------------------------------------+
void DrawTradeObjects(const int ratesTotal, const datetime &time[])
  {
   string names[] = {"lvE", "lvT1", "lvT2", "lvT3", "lvS", "pxE", "pxT1", "pxT2", "pxT3", "pxS", "bxT1", "bxT2", "bxT3", "bxS"};
   if(g_entry == EMPTY_VALUE || g_tradeBar < 0)
     {
      for(int k = 0; k < ArraySize(names); k++)
         ObjDelete(g_prefix + names[k]);
      return;
     }
   int sec = PeriodSeconds();
   datetime t1 = time[g_tradeBar];
   datetime tEnd = (datetime)((long)time[ratesTotal - 1] + (long)sec * InpPriceLabelOffset);
   double lv[5];
   lv[0] = g_entry;
   lv[1] = g_tp1;
   lv[2] = g_tp2;
   lv[3] = g_tp3;
   lv[4] = g_sl;
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
      ObjBox(g_prefix + "bxT1", t1, g_entry, tEnd, g_tp1, Blend(InpTp1Color, bg, 0.18));
      ObjBox(g_prefix + "bxT2", t1, g_tp1, tEnd, g_tp2, Blend(InpTp2Color, bg, 0.13));
      ObjBox(g_prefix + "bxT3", t1, g_tp2, tEnd, g_tp3, Blend(InpTp3Color, bg, 0.10));
      ObjBox(g_prefix + "bxS", t1, g_entry, tEnd, g_sl, Blend(InpSlColor, bg, 0.15));
     }
   else
      for(int k = 10; k < 14; k++)
         ObjDelete(g_prefix + names[k]);
  }

void DrawPatternObjects(const int ratesTotal, const datetime &time[])
  {
   int sec = PeriodSeconds();
   int dir = (int)B_dir[ratesTotal - 1];
   //--- Key levels
   for(int j = 0; j < 5; j++)
     {
      string ns = g_prefix + "kS" + IntegerToString(j);
      string nr = g_prefix + "kR" + IntegerToString(j);
      if(InpShowKeyLevels && j < ArraySize(g_kSupPrice) && g_kSupBar[j] >= 0)
         ObjLine(ns, time[g_kSupBar[j]], g_kSupPrice[j], (datetime)((long)time[g_kSupBar[j]] + sec), g_kSupPrice[j], InpSupportColor, STYLE_DOT, 1, true);
      else
         ObjDelete(ns);
      if(InpShowKeyLevels && j < ArraySize(g_kResPrice) && g_kResBar[j] >= 0)
         ObjLine(nr, time[g_kResBar[j]], g_kResPrice[j], (datetime)((long)time[g_kResBar[j]] + sec), g_kResPrice[j], InpResistanceColor, STYLE_DOT, 1, true);
      else
         ObjDelete(nr);
     }
   //--- Diagonal trend lines through the last two pivots
   bool risingSupport = g_prevSupB >= 0 && g_lastSupB >= 0 && g_lastSupP > g_prevSupP;
   bool fallingResistance = g_prevResB >= 0 && g_lastResB >= 0 && g_lastResP < g_prevResP;
   bool allowSup = InpShowTrendlines && g_prevSupB >= 0 && g_lastSupB >= 0 && (!InpOnlyCurrentSlope || (dir < 0 && risingSupport));
   bool allowRes = InpShowTrendlines && g_prevResB >= 0 && g_lastResB >= 0 && (!InpOnlyCurrentSlope || (dir > 0 && fallingResistance));
   if(allowSup)
      ObjLine(g_prefix + "tlS", time[g_prevSupB], g_prevSupP, time[g_lastSupB], g_lastSupP, InpSupportColor, STYLE_SOLID, 2, true);
   else
      ObjDelete(g_prefix + "tlS");
   if(allowRes)
      ObjLine(g_prefix + "tlR", time[g_prevResB], g_prevResP, time[g_lastResB], g_lastResP, InpResistanceColor, STYLE_SOLID, 2, true);
   else
      ObjDelete(g_prefix + "tlR");
   //--- Parallel channel
   string chName = g_prefix + "chan";
   bool drawn = false;
   if(InpShowChannel)
     {
      double supAtRes = g_lastResB >= 0 ? LineAt(g_prevSupB, g_prevSupP, g_lastSupB, g_lastSupP, g_lastResB) : EMPTY_VALUE;
      double resAtSup = g_lastSupB >= 0 ? LineAt(g_prevResB, g_prevResP, g_lastResB, g_lastResP, g_lastSupB) : EMPTY_VALUE;
      bool supValid = supAtRes != EMPTY_VALUE && g_lastResP != EMPTY_VALUE && g_lastResP > supAtRes
                      && (!InpOnlyCurrentSlope || (dir < 0 && g_lastSupP > g_prevSupP));
      bool resValid = resAtSup != EMPTY_VALUE && g_lastSupP != EMPTY_VALUE && g_lastSupP < resAtSup
                      && (!InpOnlyCurrentSlope || (dir > 0 && g_lastResP < g_prevResP));
      if(supValid || resValid)
        {
         int b1, b2;
         double p1, p2, width;
         if(supValid)
           {
            b1 = g_prevSupB;
            b2 = g_lastSupB;
            p1 = g_prevSupP;
            p2 = g_lastSupP;
            width = g_lastResP - supAtRes;
           }
         else
           {
            b1 = g_prevResB;
            b2 = g_lastResB;
            p1 = g_prevResP;
            p2 = g_lastResP;
            width = -(resAtSup - g_lastSupP);
           }
         if(ObjectFind(0, chName) < 0)
            ObjectCreate(0, chName, OBJ_CHANNEL, 0, time[b1], p1, time[b2], p2, time[b1], p1 + width);
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

   color bg = Blend(ChartBg(), ChartFg(), 0.88);
   string bgName = pfx + "bg";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
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

   for(int k = 0; k < n; k++)
     {
      int r = k / g_tCols, c = k % g_tCols;
      if(g_tTxt[k] == "")
         continue;
      int colX = 6;
      for(int j = 0; j < c; j++)
         colX += colW[j];
      int rowY = 3 + r * rowH;
      string name = pfx + IntegerToString(k);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
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

string ThState(const int state)
  {
   return state > 0 ? "ขาขึ้น" : state < 0 ? "ขาลง" : "กลาง";
  }

// TradingView trendScore: ADX below the range level = 50 (neutral), uptrend = 50 + ADX, downtrend = 50 - ADX.
double TrendScore(const int dir, const double adx)
  {
   if(dir == 0 || adx == EMPTY_VALUE || adx < InpAdxRangeLevel)
      return 50.0;
   double b = MathMin(adx, 50.0);
   return dir < 0 ? 50.0 + b : 50.0 - b;
  }

// 1 = bullish, -1 = bearish, 0 = neutral
int TrendState(const int dir, const double adx)
  {
   double s = TrendScore(dir, adx);
   if(s >= 50.0 - InpNeutralZone && s <= 50.0 + InpNeutralZone)
      return 0;
   return dir < 0 ? 1 : -1;
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

void DrawDashboards()
  {
   ArrayInitialize(g_stack, 0);
   color fg = ChartFg();
   color headClr = InpEntryColor;
   bool hideAll = InpHideAllDashboards || !g_haveData;

   //--- Statistics
   if(!hideAll && InpStatsMode != DASH_HIDDEN)
     {
      int secs = PeriodSecondsOfStats();
      datetime cutoff = secs > 0 ? g_dashNow - secs : 0;
      int signals = 0, wins = 0, losses = 0;
      double sumR = 0.0;
      for(int k = 0; k < g_recCount; k++)
        {
         if(g_recs[k].time < cutoff)
            continue;
         signals++;
         if(g_recs[k].resolved)
           {
            sumR += g_recs[k].statR;
            if(g_recs[k].win)
               wins++;
            else
               losses++;
           }
        }
      int closed = wins + losses;
      string wr = closed > 0 ? DoubleToString(100.0 * wins / closed, 1) + " %" : "-";
      color pc = sumR >= 0.0 ? InpUpColor : InpDownColor;
      string tipWr = "ชนะ ÷ เทรดที่รู้ผล × 100 · สมมติปิดทั้งหมดที่ TP1 หรือ SL หรือเมื่อเกิดสัญญาณกลับทิศ";
      string tipR = "ผลรวมกำไร/ขาดทุนเป็นหน่วย R (1R = ระยะ SL) · ยังไม่หักสเปรด";
      TBegin(2);
      if(InpStatsMode == DASH_COMPACT)
        {
         TCell("อัตราชนะ (" + PeriodText() + ")", headClr, tipWr);
         TCell(wr, fg, tipWr);
         TCell("กำไร", pc, tipR);
         TCell(DoubleToString(sumR, 2) + " R", pc, tipR);
        }
      else
        {
         TCell("สถิติย้อนหลัง · " + PeriodText(), headClr, "นับสัญญาณที่เกิดในช่วงเวลาที่เลือก จากแท่งที่คำนวณบนกราฟนี้");
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

   //--- Multi-timeframe
   if(!hideAll && InpMtfMode != DASH_HIDDEN)
     {
      ENUM_TIMEFRAMES tfs[5] = {PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
      string names[5] = {"M5", "M15", "H1", "H4", "D1"};
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
         int dir = 0;
         double adx = EMPTY_VALUE;
         if(CopyRates(_Symbol, tfs[k], 0, 400, r) > InpAtrPeriod + InpAdxLength + InpAdxSmoothing)
           {
            int d[];
            RatesSupertrend(r, d);
            dir = d[ArraySize(d) - 1];
            adx = RatesAdxLast(r);
           }
         double sc = TrendScore(dir, adx);
         int state = TrendState(dir, adx);
         color sclr = state > 0 ? InpUpColor : state < 0 ? InpDownColor : fg;
         string arrow = state > 0 ? "▲" : state < 0 ? "▼" : "•";
         if(InpMtfMode == DASH_COMPACT)
            TCell(names[k] + " " + arrow, sclr, names[k] + ": " + ThState(state) + " (คะแนน " + DoubleToString(sc, 0) + ") · ▲ ขึ้น ▼ ลง • กลาง");
         else
           {
            TCell(names[k], fg);
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
      for(int k = g_recCount - 1; k >= 0 && shown < maxRows; k--)
        {
         if(!g_recs[k].histDone)
            continue;
         shown++;
         string oc = g_recs[k].outcome == "REV" ? "กลับทิศ" : g_recs[k].outcome;
         TCell(IntegerToString(shown), fg);
         TCell(g_recs[k].side > 0 ? "ซื้อ" : "ขาย", g_recs[k].side > 0 ? InpUpColor : InpDownColor);
         TCell(oc, g_recs[k].outcome == "SL" ? InpDownColor : g_recs[k].outcome == "REV" ? fg : InpUpColor, tipOutcome);
         TCell(DoubleToString(g_recs[k].histR, 2) + "R", g_recs[k].histR >= 0.0 ? InpUpColor : InpDownColor);
         TCell(g_recs[k].slHit ? "ใช่" : "ไม่", g_recs[k].slHit ? InpDownColor : InpUpColor);
        }
      TEnd("hist", InpHistoryCorner);
     }
   else
      ObjectsDeleteAll(0, g_prefix + "Dhist_");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Indicator events                                                 |
//+------------------------------------------------------------------+
void ResetState(const int ratesTotal)
  {
   g_first = MathMax(0, ratesTotal - MathMax(InpMaxBars, 300));
   g_lastClosed = g_first;   // first bar has no previous bar for a signal
   g_tDir = 0;
   g_entry = EMPTY_VALUE;
   g_sl = EMPTY_VALUE;
   g_tp1 = EMPTY_VALUE;
   g_tp2 = EMPTY_VALUE;
   g_tp3 = EMPTY_VALUE;
   g_tradeBar = -1;
   g_tp1Reached = false;
   g_tp2Reached = false;
   g_tp3Reached = false;
   g_resolved = false;
   g_histRecorded = false;
   g_reLongArmed = false;
   g_reShortArmed = false;
   g_emaLongPull = false;
   g_emaShortPull = false;
   g_prevSupP = EMPTY_VALUE;
   g_lastSupP = EMPTY_VALUE;
   g_prevResP = EMPTY_VALUE;
   g_lastResP = EMPTY_VALUE;
   g_prevSupB = -1;
   g_lastSupB = -1;
   g_prevResB = -1;
   g_lastResB = -1;
   ArrayResize(g_kSupPrice, 0);
   ArrayResize(g_kResPrice, 0);
   ArrayResize(g_kSupBar, 0);
   ArrayResize(g_kResBar, 0);
   ArrayResize(g_recs, 0);
   g_recCount = 0;
   ObjectsDeleteAll(0, g_prefix);
  }

int OnInit()
  {
   if(InpFactor <= 0.0 || InpAtrPeriod < 1 || InpSlAtrMult <= 0.0 || InpTp1R <= 0.0 || InpTp2R <= 0.0 || InpTp3R <= 0.0
      || InpAdxLength < 1 || InpAdxSmoothing < 1 || InpPivotLength < 1 || InpKeyLevelsCount < 1)
     {
      Print("ST TP/SL: ค่าที่ตั้งไม่ถูกต้อง (ต้องมากกว่า 0)");
      return INIT_PARAMETERS_INCORRECT;
     }
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
   SetIndexBuffer(22, B_upper, INDICATOR_CALCULATIONS);
   SetIndexBuffer(23, B_lower, INDICATOR_CALCULATIONS);
   SetIndexBuffer(24, B_trur, INDICATOR_CALCULATIONS);
   SetIndexBuffer(25, B_plusS, INDICATOR_CALCULATIONS);
   SetIndexBuffer(26, B_minusS, INDICATOR_CALCULATIONS);
   SetIndexBuffer(27, B_dx, INDICATOR_CALCULATIONS);
   SetIndexBuffer(28, B_adxRaw, INDICATOR_CALCULATIONS);

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
   if(!InpShowSignals)
     {
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   if(!InpUseEma200Filter)
      PlotIndexSetInteger(6, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpReentryEma && !InpReentryEmaFast)
      PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_NONE);

   g_htfOn = InpHtfFilterTf != PERIOD_CURRENT && PeriodSeconds(InpHtfFilterTf) > PeriodSeconds();
   if(InpHtfFilterTf != PERIOD_CURRENT && !g_htfOn)
      Print("ST TP/SL: ไม่ใช้ตัวกรอง TF ใหญ่ เพราะ ", TfName(InpHtfFilterTf), " ไม่ใหญ่กว่า ", TfName(PERIOD_CURRENT));

   MathSrand((uint)GetTickCount());
   g_prefix = "STI" + IntegerToString(MathRand()) + "_";
   IndicatorSetString(INDICATOR_SHORTNAME, "ST TP/SL v" + IND_VERSION);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
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
   if(g_haveData)
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
      return 0;
   bool full = prev_calculated == 0 || prev_calculated > rates_total;
   int start;
   if(full)
     {
      ResetState(rates_total);
      for(int i = 0; i < g_first; i++)
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
         B_upper[i] = EMPTY_VALUE;
         B_lower[i] = EMPTY_VALUE;
         B_trur[i] = EMPTY_VALUE;
         B_plusS[i] = EMPTY_VALUE;
         B_minusS[i] = EMPTY_VALUE;
         B_dx[i] = EMPTY_VALUE;
         B_adxRaw[i] = EMPTY_VALUE;
        }
      start = g_first;
     }
   else
      start = prev_calculated - 1;

   bool newClosed = rates_total - 2 > g_lastClosed;
   //--- The higher-timeframe series must include the candles that closed since the last call.
   if(g_htfOn && (full || newClosed) && !LoadHtf(time[g_first]))
      return full ? 0 : prev_calculated;

   for(int i = start; i < rates_total; i++)
      StepBar(i, open, high, low, close);

   for(int i = g_lastClosed + 1; i <= rates_total - 2; i++)
      ProcessClosedBar(i, rates_total, time, high, low, close, !full);
   if(rates_total - 2 > g_lastClosed)
      g_lastClosed = rates_total - 2;

   //--- Dashboard values from the current candle (same as TradingView barstate.islast)
   int last = rates_total - 1;
   g_dashAdx = B_adx[last];
   g_dashDir = (int)B_dir[last];
   g_dashPlusDi = (B_trur[last] != EMPTY_VALUE && B_trur[last] > 0.0 && B_plusS[last] != EMPTY_VALUE) ? 100.0 * B_plusS[last] / B_trur[last] : EMPTY_VALUE;
   g_dashMinusDi = (B_trur[last] != EMPTY_VALUE && B_trur[last] > 0.0 && B_minusS[last] != EMPTY_VALUE) ? 100.0 * B_minusS[last] / B_trur[last] : EMPTY_VALUE;
   g_dashNow = time[last];
   g_haveData = true;

   if(full || newClosed)
     {
      DrawTradeObjects(rates_total, time);
      DrawPatternObjects(rates_total, time);
      DrawDashboards();
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
