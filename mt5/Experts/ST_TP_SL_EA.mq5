//+------------------------------------------------------------------+
//|                                                  ST_TP_SL_EA.mq5 |
//|  Expert Advisor for the Supertrend TP/SL indicator.              |
//|                                                                  |
//|  The indicator (Indicators/ST_TP_SL.mq5) is embedded as a        |
//|  resource. The EA reads its signal buffers on the trade          |
//|  timeframe, so the BUY/SELL labels on the chart and the orders   |
//|  always come from the same code.                                 |
//|                                                                  |
//|  Order levels: Entry/SL/TP of the signal candle close (same as   |
//|  the chart), then adjusted by the live spread: SL moved away     |
//|  from the entry by the spread, every TP moved closer by it.      |
//|                                                                  |
//|  Hedging account: one position per TP (TP1, TP2, TP3) with the   |
//|  same SL, closed by the broker. Netting account: one position    |
//|  with the furthest TP; the EA closes the TP1/TP2 parts.          |
//|                                                                  |
//|  Install: copy Indicators/ST_TP_SL.mq5 to MQL5\Indicators and    |
//|  this file to MQL5\Experts, compile the indicator, then the EA.  |
//+------------------------------------------------------------------+
#property copyright   "Trading-signals67"
#property link        "https://github.com/maung5678/Trading-signals67"
#property version     "1.10"
#property description "Supertrend TP/SL EA v1.10: เปิดออเดอร์ตามป้าย BUY/SELL ของอินดิเคเตอร์ พร้อม SL และ TP1–TP3"

#resource "\\Indicators\\ST_TP_SL.ex5"
#include <Trade/Trade.mqh>

#define EA_VERSION "1.10"
#define IND_PATH   "::Indicators\\ST_TP_SL.ex5"
//--- Indicator buffer numbers
#define BUF_ST    3
#define BUF_SIG   13
#define BUF_ENTRY 14
#define BUF_SL    15
#define BUF_TP1   16
#define BUF_TP2   17
#define BUF_TP3   18
#define BUF_DIR   19

enum ENUM_LOT_MODE
  {
   LOT_RISK_PERCENT = 0, // ตามเงินทุน (เสี่ยง % ของบาลานซ์ต่อเทรด)
   LOT_FIXED = 1         // ล็อตคงที่ (รวมทุก TP)
  };

enum ENUM_OPPOSITE_MODE
  {
   OPPOSITE_ON_SIGNAL = 0, // ปิดเมื่อมีป้ายฝั่งตรงข้ามบนกราฟ (เหมือนอินดิเคเตอร์)
   OPPOSITE_ON_FLIP = 1,   // ปิดทุกครั้งที่ Supertrend กลับทิศ (แม้ไม่มีป้าย)
   OPPOSITE_NEVER = 2      // ไม่ปิด ปล่อยให้ชน SL / TP เอง
  };

enum ENUM_LOSS_LIMIT_TYPE
  {
   LOSS_PERCENT = 0, // % ของบาลานซ์
   LOSS_MONEY = 1    // จำนวนเงิน (สกุลเงินบัญชี)
  };

//--- Same enums as the indicator (values must match)
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

//--- Main settings
input group "ตั้งค่าหลัก"
input ENUM_TIMEFRAMES    InpTradeTf        = PERIOD_M15;         // TF ที่ใช้เทรด (ไม่ขึ้นกับ TF ของกราฟ)
input ENUM_LOT_MODE      InpLotMode        = LOT_RISK_PERCENT;   // วิธีคิดล็อต
input double             InpRiskPercent    = 1.0;                // เสี่ยง % ต่อเทรด (โหมดตามเงินทุน)
input double             InpFixedLots      = 0.03;               // ล็อตรวม (โหมดล็อตคงที่)
input double             InpMaxTotalLots   = 0.0;                // ล็อตรวมสูงสุด (0 = ไม่จำกัด)
input double             InpPart1Pct       = 34.0;               // สัดส่วนปิดที่ TP1 (%)
input double             InpPart2Pct       = 33.0;               // สัดส่วนปิดที่ TP2 (%)
input double             InpPart3Pct       = 33.0;               // สัดส่วนปิดที่ TP3 (%)
input ENUM_OPPOSITE_MODE InpOppositeMode   = OPPOSITE_ON_SIGNAL; // ออเดอร์เดิมเมื่อเทรนด์กลับ
input ulong              InpMagic          = 0;                  // Magic number (0 = สร้างเองจากคู่เงิน + TF)
input int                InpSlippagePts    = 30;                 // Slippage สูงสุด (points)
input int                InpMaxDelayPct    = 50;                 // เข้าได้ภายในกี่ % ของแท่งหลังสัญญาณปิด
input bool               InpEaPush         = true;               // ส่งแจ้งเตือนเข้าแอป MT5 มือถือ
input bool               InpEaPopup        = false;              // แสดง Alert popup บนคอม
input bool               InpShowIndicator  = true;               // แสดงอินดิเคเตอร์บนกราฟ (เมื่อ TF ตรงกัน)
input bool               InpShowPanel      = true;               // แสดงแผงสถานะ EA
input bool               InpShowSentLevels = true;               // แสดงราคา SL/TP ที่ส่งจริง (ตัวเล็ก)

//--- Indicator settings (passed to the embedded indicator)
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
input ENUM_DASH_MODE    InpStatsMode         = DASH_COMPACT;       // สถิติชนะ/แพ้ของสัญญาณ
input ENUM_STATS_PERIOD InpStatsPeriod       = STATS_ALL;          // ช่วงเวลาของสถิติ
input ENUM_BASE_CORNER  InpStatsCorner       = CORNER_RIGHT_UPPER; // ตำแหน่งสถิติ
input ENUM_DASH_MODE    InpAdxMode           = DASH_COMPACT;       // แดชบอร์ด ADX
input ENUM_BASE_CORNER  InpAdxCorner         = CORNER_RIGHT_UPPER; // ตำแหน่ง ADX
input ENUM_DASH_MODE    InpMtfMode           = DASH_COMPACT;       // เทรนด์หลายไทม์เฟรม
input ENUM_BASE_CORNER  InpMtfCorner         = CORNER_RIGHT_LOWER; // ตำแหน่งเทรนด์หลายไทม์เฟรม
input ENUM_DASH_MODE    InpHistoryMode       = DASH_HIDDEN;        // ประวัติเทรด
input ENUM_BASE_CORNER  InpHistoryCorner     = CORNER_LEFT_LOWER;  // ตำแหน่งประวัติเทรด
input int               InpDashFontSize      = 8;                  // ขนาดตัวอักษรแดชบอร์ด

//--- Optional features (all off by default)
input group "ตัวเลือกเสริม: บริหารออเดอร์ (ค่าเริ่มต้นปิด)"
input bool              InpBeAfterTp1        = false; // ถึง TP1 แล้วเลื่อน SL ไปจุดเข้า (กันทุน)
input int               InpBeOffsetPts       = 0;     // กันทุนบวกเพิ่ม (points)
input bool              InpSlToTp1AfterTp2   = false; // ถึง TP2 แล้วเลื่อน SL ไป TP1
input bool              InpTrailSupertrend   = false; // Trailing stop ตามเส้น Supertrend
input bool              InpTrailNoTp3        = false; // ใช้ Trailing แล้วไม่ตั้ง TP3 (ปล่อยวิ่งตามเทรนด์)
input group "ตัวเลือกเสริม: ตัวกรองของ EA (ค่าเริ่มต้นปิด)"
input bool              InpUseSpreadFilter   = false;         // กรองสเปรด
input double            InpMaxSpreadPctOfSl  = 10.0;          // สเปรดไม่เกิน % ของระยะ SL
input bool              InpUseTradeHours     = false;         // เทรดเฉพาะช่วงเวลา
input string            InpTradeHours        = "08:00-22:00"; // ช่วงเวลา (เวลาเซิร์ฟเวอร์ HH:MM-HH:MM)
input bool              InpUseDailyLossLimit = false;         // จำกัดขาดทุนต่อวัน
input ENUM_LOSS_LIMIT_TYPE InpDailyLossType  = LOSS_PERCENT;  // หน่วยของขาดทุนต่อวัน
input double            InpDailyLossValue    = 3.0;           // ขาดทุนต่อวันสูงสุด
input bool              InpUseMaxTradesDay   = false;         // จำกัดจำนวนเทรดต่อวัน
input int               InpMaxTradesPerDay   = 5;             // จำนวนเทรดสูงสุดต่อวัน
input bool              InpUseCooldown       = false;         // พักหลังโดน SL
input int               InpCooldownBars      = 3;             // พักกี่แท่ง (ของ TF ที่เทรด)
input bool              InpUseNewsFilter     = false;         // หยุดเข้าช่วงข่าว (ปฏิทินของ MT5)
input int               InpNewsMinutesBefore = 30;            // หยุดก่อนข่าว (นาที)
input int               InpNewsMinutesAfter  = 30;            // หยุดหลังข่าว (นาที)
input bool              InpNewsIncludeMedium = false;         // รวมข่าวความสำคัญปานกลาง
input group "ตัวเลือกเสริม: ตัวกรองสัญญาณของอินดิเคเตอร์ (ค่าเริ่มต้นปิด)"
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
input group "ตัวเลือกเสริม: แดชบอร์ดผลงานจริงของ EA (ค่าเริ่มต้นปิด)"
input ENUM_DASH_MODE    InpResultsMode       = DASH_HIDDEN;       // ผลงานจริง (เงินจากประวัติบัญชี)
input ENUM_BASE_CORNER  InpResultsCorner     = CORNER_LEFT_UPPER; // ตำแหน่งผลงานจริง
input group "ค่าคำนวณ ADX / หลายไทม์เฟรม"
input int               InpAdxLength         = 14;    // ADX: ความยาว DI
input int               InpAdxSmoothing      = 14;    // ADX: การปรับเรียบ
input double            InpAdxRangeLevel     = 20.0;  // ADX ต่ำกว่านี้ = ไซด์เวย์
input double            InpAdxStrongLevel    = 25.0;  // ADX ตั้งแต่นี้ = เทรนด์แรง
input double            InpNeutralZone       = 10.0;  // โซนกลาง ± (หลายไทม์เฟรม)

//--- Globals
CTrade          g_trade;
int             g_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_tf = PERIOD_M15;
ulong           g_magic = 0;
bool            g_netting = false;
bool            g_indAdded = false;
string          g_indName = "";
string          g_objPrefix = "";
datetime        g_lastBarTime = 0;
datetime        g_modifyBlockedUntil = 0;
int             g_lastDir = 0;
string          g_lastEvent = "-";
string          g_filterState = "ปกติ";
bool            g_resultsDirty = true;
datetime        g_resultsTime = 0;
MqlParam        g_params[];

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string TfName(const ENUM_TIMEFRAMES tf)
  {
   ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   return StringSubstr(EnumToString(t), 7);   // "PERIOD_M15" -> "M15"
  }

string Fmt(const double price) { return DoubleToString(price, _Digits); }

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

// Magic number from symbol + trade timeframe, so several charts never mix their orders.
ulong AutoMagic()
  {
   string s = _Symbol + "|" + IntegerToString(PeriodSeconds(g_tf));
   ulong h = 5381;
   for(int i = 0; i < StringLen(s); i++)
      h = ((h << 5) + h) + (ulong)StringGetCharacter(s, i);
   return 670000000 + (h % 1000000);
  }

string GvPrefix()               { return "ST67_" + IntegerToString((long)g_magic) + "_"; }
string GvPos(const ulong ticket) { return GvPrefix() + "P" + IntegerToString((long)ticket); }

double GvGet(const string name, const double fallback)
  {
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : fallback;
  }

long DayNumber()
  {
   return (long)TimeCurrent() / 86400;
  }

void Notify(const string msg, const bool push = true)
  {
   Print(msg);
   string oneLine = msg;
   StringReplace(oneLine, "\n", " · ");
   g_lastEvent = TimeToString(TimeCurrent(), TIME_MINUTES) + " " + oneLine;
   if(!push)
      return;
   if(InpEaPopup)
      Alert(msg);
   if(InpEaPush && !MQLInfoInteger(MQL_TESTER))
      SendNotification(StringSubstr(msg, 0, 255));
  }

// Thai text for the trade server return codes seen most often.
string RetcodeTh(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:            return "ราคาเปลี่ยน (requote) ลองใหม่";
      case TRADE_RETCODE_REJECT:             return "โบรกปฏิเสธคำสั่ง";
      case TRADE_RETCODE_CANCEL:             return "คำสั่งถูกยกเลิก";
      case TRADE_RETCODE_ERROR:              return "เกิดข้อผิดพลาดในการส่งคำสั่ง";
      case TRADE_RETCODE_TIMEOUT:            return "เซิร์ฟเวอร์ตอบช้าเกินเวลา";
      case TRADE_RETCODE_INVALID:            return "คำสั่งไม่ถูกต้อง";
      case TRADE_RETCODE_INVALID_VOLUME:     return "ล็อตไม่ถูกต้อง";
      case TRADE_RETCODE_INVALID_PRICE:      return "ราคาไม่ถูกต้อง";
      case TRADE_RETCODE_INVALID_STOPS:      return "SL/TP ใกล้ราคาเกินไปหรือไม่ถูกต้อง";
      case TRADE_RETCODE_TRADE_DISABLED:     return "บัญชีหรือคู่นี้ปิดการเทรด";
      case TRADE_RETCODE_MARKET_CLOSED:      return "ตลาดปิด";
      case TRADE_RETCODE_NO_MONEY:           return "มาร์จิ้นไม่พอ";
      case TRADE_RETCODE_PRICE_CHANGED:      return "ราคาเปลี่ยนระหว่างส่งคำสั่ง";
      case TRADE_RETCODE_PRICE_OFF:          return "ไม่มีราคาเสนอขณะนี้";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "ส่งคำสั่งถี่เกินไป";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "เซิร์ฟเวอร์ปิดการเทรดอัตโนมัติ";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "ยังไม่ได้เปิดปุ่ม Algo Trading";
      case TRADE_RETCODE_INVALID_FILL:       return "โบรกไม่รองรับรูปแบบการจับคู่คำสั่ง (filling)";
      case TRADE_RETCODE_CONNECTION:         return "ไม่ได้เชื่อมต่อเซิร์ฟเวอร์";
      case TRADE_RETCODE_LIMIT_ORDERS:       return "จำนวนคำสั่งรอเกินที่โบรกกำหนด";
      case TRADE_RETCODE_LIMIT_VOLUME:       return "ล็อตรวมเกินที่โบรกกำหนด";
      case TRADE_RETCODE_LIMIT_POSITIONS:    return "จำนวนออเดอร์เกินที่โบรกกำหนด";
      case TRADE_RETCODE_CLOSE_ONLY:         return "คู่นี้อนุญาตให้ปิดออเดอร์ได้อย่างเดียว";
      case TRADE_RETCODE_FROZEN:             return "ออเดอร์อยู่ใกล้ราคาเกินไป แก้ไขไม่ได้ (freeze level)";
     }
   return "รหัส " + IntegerToString((int)rc) + " (" + g_trade.ResultRetcodeDescription() + ")";
  }

//+------------------------------------------------------------------+
//| Indicator parameters (order = indicator input order, colors      |
//| excluded). One ParamX(...) per line: tools/check_inputs.py       |
//| compares this list with the indicator.                           |
//+------------------------------------------------------------------+
void ParamAdd(const ENUM_DATATYPE type, const long iv, const double dv, const string sv)
  {
   int n = ArraySize(g_params);
   ArrayResize(g_params, n + 1);
   g_params[n].type = type;
   g_params[n].integer_value = iv;
   g_params[n].double_value = dv;
   g_params[n].string_value = sv;
  }
void ParamStr(const string v)  { ParamAdd(TYPE_STRING, 0, 0.0, v); }
void ParamInt(const long v)    { ParamAdd(TYPE_INT, v, 0.0, ""); }
void ParamDbl(const double v)  { ParamAdd(TYPE_DOUBLE, 0, v, ""); }
void ParamBool(const bool v)   { ParamAdd(TYPE_BOOL, v ? 1 : 0, 0.0, ""); }

void BuildIndicatorParams()
  {
   ArrayResize(g_params, 0);
   ParamStr(IND_PATH);
   ParamDbl(InpFactor);
   ParamInt(InpAtrPeriod);
   ParamDbl(InpSlAtrMult);
   ParamDbl(InpTp1R);
   ParamDbl(InpTp2R);
   ParamDbl(InpTp3R);
   ParamBool(InpShowSignals);
   ParamBool(InpShowTrendLine);
   ParamBool(InpShowFill);
   ParamBool(InpShowCandleColors);
   ParamBool(InpShowLevels);
   ParamBool(InpShowBoxes);
   ParamBool(InpShowTpMarks);
   ParamBool(InpShowPriceLabels);
   ParamInt(InpPriceLabelOffset);
   ParamInt(InpMaxBars);
   ParamInt(InpObjectBars);
   ParamBool(InpHideAllDashboards);
   ParamInt(InpStatsMode);
   ParamInt(InpStatsPeriod);
   ParamInt(InpStatsCorner);
   ParamInt(InpAdxMode);
   ParamInt(InpAdxCorner);
   ParamInt(InpMtfMode);
   ParamInt(InpMtfCorner);
   ParamInt(InpHistoryMode);
   ParamInt(InpHistoryCorner);
   ParamInt(InpDashFontSize);
   ParamBool(false); // InpAlertOnSignal (the EA sends its own notifications)
   ParamBool(false); // InpAlertOnTpSl
   ParamBool(false); // InpAlertPopup
   ParamBool(false); // InpAlertPush
   ParamBool(InpUseAdxFilter);
   ParamDbl(InpAdxSignalMin);
   ParamInt(InpHtfFilterTf);
   ParamBool(InpUseEma200Filter);
   ParamBool(InpBreakoutSignals);
   ParamBool(InpReentrySt);
   ParamBool(InpReentryEma);
   ParamBool(InpReentryEmaFast);
   ParamInt(InpReentryEmaLength);
   ParamBool(InpShowKeyLevels);
   ParamBool(InpShowTrendlines);
   ParamBool(InpShowChannel);
   ParamBool(InpOnlyCurrentSlope);
   ParamInt(InpPivotLength);
   ParamInt(InpKeyLevelsCount);
   ParamDbl(InpKeyLevelTolAtr);
   ParamInt(InpAdxLength);
   ParamInt(InpAdxSmoothing);
   ParamDbl(InpAdxRangeLevel);
   ParamDbl(InpAdxStrongLevel);
   ParamDbl(InpNeutralZone);
  }

//+------------------------------------------------------------------+
//| Positions                                                        |
//+------------------------------------------------------------------+
bool IsOurPosition()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == g_magic;
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
      if(g_trade.PositionClose(ticket) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         closed++;
      else
         Notify(StringFormat("❌ ปิดออเดอร์ #%I64u ไม่สำเร็จ: %s", ticket, RetcodeTh(g_trade.ResultRetcode())));
     }
   if(closed > 0)
     {
      Notify(StringFormat("🔁 ปิด %s %d ออเดอร์ %s %s (%s)", side > 0 ? "BUY" : "SELL", closed, _Symbol, TfName(g_tf), why));
      g_resultsDirty = true;
     }
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
      Notify(StringFormat("❌ ส่งออเดอร์ %s %s ไม่สำเร็จ: %s", side > 0 ? "BUY" : "SELL", _Symbol, RetcodeTh(rc)));
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

void StoreLevels(const ulong ticket, const double tp1, const double tp2, const double v1, const double v2, const double spread)
  {
   string key = GvPos(ticket);
   GlobalVariableSet(key + "_T1", tp1);
   GlobalVariableSet(key + "_T2", tp2);
   GlobalVariableSet(key + "_V1", v1);
   GlobalVariableSet(key + "_V2", v2);
   GlobalVariableSet(key + "_S", 0.0);
   GlobalVariableSet(key + "_SP", spread);
  }

// Levels from the signal candle (same as the chart), adjusted by the live spread.
bool OpenGroup(const int side, const double sigEntry, const double sigSl, const double &sigTp[])
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   string sideTxt = side > 0 ? "BUY" : "SELL";
   double spread = MathMax(0.0, tick.ask - tick.bid);
   double sl = NormPrice(sigSl - side * spread);
   double tp[3];
   for(int k = 0; k < 3; k++)
      tp[k] = NormPrice(sigTp[k] - side * spread);
   double fill = side > 0 ? tick.ask : tick.bid;
   double exitPx = side > 0 ? tick.bid : tick.ask;
   double stops = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;

   if(side > 0 ? exitPx >= tp[0] : exitPx <= tp[0])
     {
      Notify(StringFormat("⏭ %s %s: ราคาตอนนี้ %s ไปถึง TP1 (%s) แล้ว ไม่เข้า", sideTxt, _Symbol, Fmt(exitPx), Fmt(tp[0])));
      return false;
     }
   if(side > 0 ? exitPx - sl <= stops : sl - exitPx <= stops)
     {
      Notify(StringFormat("⏭ %s %s: ราคาตอนนี้ %s ชิดหรือเลย SL (%s) แล้ว ไม่เข้า", sideTxt, _Symbol, Fmt(exitPx), Fmt(sl)));
      return false;
     }
   if(side > 0 ? tp[0] - exitPx <= stops : exitPx - tp[0] <= stops)
     {
      Notify(StringFormat("⏭ %s %s: TP1 ใกล้ราคาเกินกว่าที่โบรกอนุญาต ไม่เข้า", sideTxt, _Symbol));
      return false;
     }

   double total = TotalLots(side, fill, sl);
   if(total <= 0.0)
      return false;
   double vols[];
   if(!SplitVolume(total, vols))
     {
      Notify("⚠ แบ่งล็อตไม่ได้ (ล็อตรวมต่ำกว่าขั้นต่ำ) ข้ามเทรดนี้");
      return false;
     }
   bool noTp3 = InpTrailSupertrend && InpTrailNoTp3;
   int opened = 0;
   if(g_netting)
     {
      int last = -1;
      double sum = 0.0;
      for(int k = 0; k < 3; k++)
         if(vols[k] > 0.0)
           {
            last = k;
            sum += vols[k];
           }
      double tpOrder = (last == 2 && noTp3) ? 0.0 : tp[last];
      ulong ticket = SendMarket(side, NormalizeDouble(sum, 8), sl, tpOrder, "ST67 " + sideTxt);
      if(ticket > 0)
        {
         StoreLevels(ticket, tp[0], tp[1], last > 0 ? vols[0] : 0.0, last > 1 ? vols[1] : 0.0, spread);
         opened = 1;
        }
     }
   else
     {
      for(int k = 0; k < 3; k++)
        {
         if(vols[k] <= 0.0)
            continue;
         double tpOrder = (k == 2 && noTp3) ? 0.0 : tp[k];
         ulong ticket = SendMarket(side, vols[k], sl, tpOrder, StringFormat("ST67 %s TP%d", sideTxt, k + 1));
         if(ticket > 0)
           {
            StoreLevels(ticket, tp[0], tp[1], 0.0, 0.0, spread);
            opened++;
           }
        }
     }
   if(opened == 0)
      return false;

   string countKey = GvPrefix() + "N" + IntegerToString(DayNumber());
   GlobalVariableSet(countKey, GvGet(countKey, 0.0) + 1.0);
   g_resultsDirty = true;

   string msg = StringFormat("%s %s %s %s\nEntry %s (เข้าจริง ~%s)\nSL %s → ส่ง %s",
                             side > 0 ? "🟢" : "🔴", sideTxt, _Symbol, TfName(g_tf),
                             Fmt(sigEntry), Fmt(fill), Fmt(sigSl), Fmt(sl));
   for(int k = 0; k < 3; k++)
      if(vols[k] > 0.0)
         msg += StringFormat("\nTP%d %s → ส่ง %s (%.2f lot)", k + 1, Fmt(sigTp[k]), (k == 2 && noTp3) ? "ไม่ตั้ง" : Fmt(tp[k]), vols[k]);
   msg += "\nสเปรด " + Fmt(spread);
   Notify(msg);
   return true;
  }

//+------------------------------------------------------------------+
//| Stop management                                                  |
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
   double minDist = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(isBuy ? tick.bid - newSl <= minDist : newSl - tick.ask <= minDist)
      return;   // too close to the price right now, try again later
   if(g_trade.PositionModify(ticket, newSl, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      Notify(StringFormat("🛡 #%I64u %s: SL → %s", ticket, why, Fmt(newSl)), false);
   else
     {
      Print("เลื่อน SL #", ticket, " ไม่สำเร็จ: ", RetcodeTh(g_trade.ResultRetcode()));
      g_modifyBlockedUntil = TimeCurrent() + 10;
     }
  }

// Every tick: netting partial closes, break-even, SL to TP1.
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
      string key = GvPos(ticket);
      if(!GlobalVariableCheck(key + "_T1"))
         continue;
      double t1 = GlobalVariableGet(key + "_T1");
      double t2 = GvGet(key + "_T2", 0.0);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double price = isBuy ? tick.bid : tick.ask;
      bool passTp1 = isBuy ? price >= t1 : price <= t1;
      bool passTp2 = t2 > 0.0 && (isBuy ? price >= t2 : price <= t2);

      if(g_netting && TimeCurrent() >= g_modifyBlockedUntil)
        {
         double stage = GvGet(key + "_S", 0.0);
         if(stage < 1.0 && passTp1)
           {
            double v1 = GvGet(key + "_V1", 0.0);
            if(v1 <= 0.0 || v1 >= vol)
               GlobalVariableSet(key + "_S", 1.0);
            else
               if(g_trade.PositionClosePartial(ticket, v1) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
                 {
                  GlobalVariableSet(key + "_S", 1.0);
                  vol -= v1;
                  g_resultsDirty = true;
                  Notify(StringFormat("✅ TP1 %s %s ปิดบางส่วน %.2f lot ที่ ~%s", isBuy ? "BUY" : "SELL", _Symbol, v1, Fmt(price)));
                 }
               else
                 {
                  Notify("❌ ปิดบางส่วนที่ TP1 ไม่สำเร็จ: " + RetcodeTh(g_trade.ResultRetcode()), false);
                  g_modifyBlockedUntil = TimeCurrent() + 10;
                 }
            stage = GvGet(key + "_S", 0.0);
           }
         if(stage >= 1.0 && stage < 2.0 && passTp2)
           {
            double v2 = GvGet(key + "_V2", 0.0);
            if(v2 <= 0.0 || v2 >= vol)
               GlobalVariableSet(key + "_S", 2.0);
            else
               if(g_trade.PositionClosePartial(ticket, v2) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
                 {
                  GlobalVariableSet(key + "_S", 2.0);
                  g_resultsDirty = true;
                  Notify(StringFormat("✅ TP2 %s %s ปิดบางส่วน %.2f lot ที่ ~%s", isBuy ? "BUY" : "SELL", _Symbol, v2, Fmt(price)));
                 }
               else
                 {
                  Notify("❌ ปิดบางส่วนที่ TP2 ไม่สำเร็จ: " + RetcodeTh(g_trade.ResultRetcode()), false);
                  g_modifyBlockedUntil = TimeCurrent() + 10;
                 }
           }
        }

      if(InpSlToTp1AfterTp2 && passTp2)
         TryMoveSl(ticket, isBuy, sl, tp, t1, "ถึง TP2 เลื่อน SL ไป TP1");
      else
         if(InpBeAfterTp1 && passTp1)
            TryMoveSl(ticket, isBuy, sl, tp, open + (isBuy ? 1.0 : -1.0) * InpBeOffsetPts * _Point, "ถึง TP1 กันทุน");
     }
  }

// New candle of the trade timeframe: SL follows the Supertrend line (minus the spread).
void TrailSupertrend(const int dir, const double st)
  {
   if(!InpTrailSupertrend || dir == 0 || st == EMPTY_VALUE || st <= 0.0)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double spread = MathMax(0.0, tick.ask - tick.bid);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if((isBuy && dir > 0) || (!isBuy && dir < 0))
         continue;   // line on the other side: the trend flipped, the opposite-signal rule handles it
      double newSl = isBuy ? st - spread : st + spread;
      TryMoveSl(ticket, isBuy, PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), newSl, "Trailing ตาม Supertrend");
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
//| EA filters (optional)                                            |
//+------------------------------------------------------------------+
int HmToMinutes(const string text)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   string hm[];
   if(StringSplit(s, ':', hm) != 2)
      return -1;
   int h = (int)StringToInteger(hm[0]);
   int m = (int)StringToInteger(hm[1]);
   if(h < 0 || h > 24 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
  }

bool ParseHours(int &from, int &to)
  {
   string parts[];
   if(StringSplit(InpTradeHours, '-', parts) != 2)
      return false;
   from = HmToMinutes(parts[0]);
   to = HmToMinutes(parts[1]);
   return from >= 0 && to >= 0;
  }

bool InTradeHours()
  {
   int from, to;
   if(!ParseHours(from, to))
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 60 + dt.min;
   if(from == to)
      return true;
   if(from < to)
      return now >= from && now < to;
   return now >= from || now < to;   // over midnight, e.g. 22:00-06:00
  }

datetime DayStart(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
  }

// Net result (profit + swap + commission) of this EA's deals since `from`.
double ClosedNetSince(const datetime from)
  {
   double net = 0.0;
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != g_magic || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      net += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
     }
   return net;
  }

double FloatingNet()
  {
   double net = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      net += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return net;
  }

string DailyLossReason()
  {
   if(!InpUseDailyLossLimit || InpDailyLossValue <= 0.0)
      return "";
   double today = ClosedNetSince(DayStart(TimeCurrent())) + FloatingNet();
   double limit = InpDailyLossType == LOSS_PERCENT ? AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLossValue / 100.0 : InpDailyLossValue;
   if(-today >= limit)
      return StringFormat("ขาดทุนวันนี้ %.2f ถึงขีดจำกัด %.2f %s", -today, limit, AccountInfoString(ACCOUNT_CURRENCY));
   return "";
  }

string NewsReason()
  {
   if(!InpUseNewsFilter || MQLInfoInteger(MQL_TESTER))
      return "";
   string cur[2];
   cur[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   cur[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   datetime now = TimeTradeServer();
   datetime from = (datetime)((long)now - InpNewsMinutesAfter * 60);
   datetime to = (datetime)((long)now + InpNewsMinutesBefore * 60);
   for(int c = 0; c < 2; c++)
     {
      if(cur[c] == "" || (c == 1 && cur[1] == cur[0]))
         continue;
      MqlCalendarValue values[];
      if(CalendarValueHistory(values, from, to, NULL, cur[c]) <= 0)
         continue;
      for(int j = 0; j < ArraySize(values); j++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[j].event_id, ev))
            continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH || (InpNewsIncludeMedium && ev.importance == CALENDAR_IMPORTANCE_MODERATE))
            return "ข่าว " + cur[c] + " \"" + ev.name + "\" เวลา " + TimeToString(values[j].time, TIME_MINUTES);
        }
     }
   return "";
  }

// Reasons that block a NEW entry (empty = allowed).
string EaFilterReasons(const double sigEntry, const double sigSl)
  {
   string r = "";
   if(InpUseSpreadFilter)
     {
      double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double risk = MathAbs(sigEntry - sigSl);
      double pct = risk > 0.0 ? 100.0 * spread / risk : 100.0;
      if(pct > InpMaxSpreadPctOfSl)
         r += StringFormat("สเปรด %s = %.1f%% ของระยะ SL (เกิน %.1f%%); ", Fmt(spread), pct, InpMaxSpreadPctOfSl);
     }
   if(InpUseTradeHours && !InTradeHours())
      r += "นอกช่วงเวลาเทรด " + InpTradeHours + "; ";
   string loss = DailyLossReason();
   if(loss != "")
      r += loss + "; ";
   if(InpUseMaxTradesDay && GvGet(GvPrefix() + "N" + IntegerToString(DayNumber()), 0.0) >= InpMaxTradesPerDay)
      r += StringFormat("เทรดครบ %d ครั้งของวันนี้แล้ว; ", InpMaxTradesPerDay);
   if(InpUseCooldown)
     {
      double lastSl = GvGet(GvPrefix() + "LASTSL", 0.0);
      if(lastSl > 0.0 && (double)TimeCurrent() - lastSl < (double)InpCooldownBars * PeriodSeconds(g_tf))
         r += StringFormat("พักหลังโดน SL (%d แท่ง); ", InpCooldownBars);
     }
   string news = NewsReason();
   if(news != "")
      r += news + "; ";
   return r;
  }

//+------------------------------------------------------------------+
//| Signal on the candle that just closed                            |
//+------------------------------------------------------------------+
// Returns false while the indicator has not calculated the new candle yet (retry next tick).
bool OnNewSignalBar(const datetime barOpen)
  {
   int bars = Bars(_Symbol, g_tf);
   if(bars <= 2 || BarsCalculated(g_handle) < bars)
      return false;
   double sig[], dir[], st[], entry[], sl[], tp1[], tp2[], tp3[];
   datetime t[];
   ArraySetAsSeries(dir, true);
   if(CopyBuffer(g_handle, BUF_SIG, 1, 1, sig) != 1 || CopyBuffer(g_handle, BUF_DIR, 1, 2, dir) != 2
      || CopyBuffer(g_handle, BUF_ST, 1, 1, st) != 1 || CopyBuffer(g_handle, BUF_ENTRY, 1, 1, entry) != 1
      || CopyBuffer(g_handle, BUF_SL, 1, 1, sl) != 1 || CopyBuffer(g_handle, BUF_TP1, 1, 1, tp1) != 1
      || CopyBuffer(g_handle, BUF_TP2, 1, 1, tp2) != 1 || CopyBuffer(g_handle, BUF_TP3, 1, 1, tp3) != 1
      || CopyTime(_Symbol, g_tf, 1, 1, t) != 1)
      return false;

   g_lastDir = (int)dir[0];
   TrailSupertrend(g_lastDir, st[0]);

   int signal = (int)MathRound(sig[0]);
   int flip = (dir[0] < 0 && dir[1] > 0) ? 1 : (dir[0] > 0 && dir[1] < 0) ? -1 : 0;
   if(signal == 0 && flip == 0)
      return true;

   // Never act twice on the same candle (also after a terminal restart).
   string lastKey = GvPrefix() + "LAST";
   if(GlobalVariableCheck(lastKey) && (datetime)GlobalVariableGet(lastKey) >= t[0])
      return true;
   GlobalVariableSet(lastKey, (double)t[0]);

   if(InpOppositeMode == OPPOSITE_ON_FLIP && flip != 0 && CountPositions(-flip) > 0)
      CloseSide(-flip, "Supertrend กลับทิศ");
   if(signal == 0)
     {
      Notify(StringFormat("ℹ Supertrend %s กลับเป็น%s แต่ไม่มีป้าย (ตัวกรองของอินดิเคเตอร์)", _Symbol, DirText((int)dir[0])), false);
      return true;
     }
   if(InpOppositeMode == OPPOSITE_ON_SIGNAL && CountPositions(-signal) > 0)
      CloseSide(-signal, "ป้ายฝั่งตรงข้าม");

   string sideTxt = signal > 0 ? "BUY" : "SELL";
   long elapsed = (long)(TimeCurrent() - barOpen);
   if(elapsed > (long)PeriodSeconds(g_tf) * InpMaxDelayPct / 100)
     {
      Notify(StringFormat("⏭ ป้าย %s %s %s ผ่านมานานแล้ว (EA เพิ่งเริ่ม) ไม่เข้า", sideTxt, _Symbol, TfName(g_tf)), false);
      return true;
     }
   if(entry[0] == EMPTY_VALUE || sl[0] == EMPTY_VALUE || tp1[0] == EMPTY_VALUE)
      return true;
   string blocked = EaFilterReasons(entry[0], sl[0]);
   if(blocked != "")
     {
      Notify(StringFormat("⏸ ป้าย %s %s %s ไม่เข้า: %s", sideTxt, _Symbol, TfName(g_tf), blocked));
      return true;
     }
   if(CountPositions(signal) > 0)
     {
      Notify(StringFormat("ℹ ป้าย %s %s แต่ยังมีออเดอร์ฝั่งเดียวกันเปิดอยู่ ไม่เปิดซ้อน", sideTxt, _Symbol), false);
      return true;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Notify(StringFormat("⚠ ป้าย %s %s แต่ยังไม่ได้เปิด Algo Trading จึงไม่ได้เข้า", sideTxt, _Symbol));
      return true;
     }
   double tps[3];
   tps[0] = tp1[0];
   tps[1] = tp2[0];
   tps[2] = tp3[0];
   OpenGroup(signal, entry[0], sl[0], tps);
   return true;
  }

//+------------------------------------------------------------------+
//| Panel, real results and sent levels                              |
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
   string pfx = g_objPrefix + "D" + id + "_";
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

string LotText()
  {
   if(InpLotMode == LOT_RISK_PERCENT)
      return StringFormat("ตามเงินทุน เสี่ยง %.2f%%", InpRiskPercent);
   return StringFormat("คงที่ %.2f lot", InpFixedLots);
  }

// Lots of open EA positions per side.
double OpenLots(const int side)
  {
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((side > 0 && type == POSITION_TYPE_BUY) || (side < 0 && type == POSITION_TYPE_SELL))
         lots += PositionGetDouble(POSITION_VOLUME);
     }
   return lots;
  }

void DrawPanel()
  {
   if(!InpShowPanel)
     {
      ObjectsDeleteAll(0, g_objPrefix + "Dpanel_");
      return;
     }
   color fg = ChartFg();
   color head = C'91,156,246';
   color up = C'8,153,129', down = C'242,54,69';
   string last = g_lastEvent;
   if(StringLen(last) > 70)
      last = StringSubstr(last, 0, 67) + "...";
   TBegin(2);
   TCell("ST TP/SL EA v" + EA_VERSION, head);
   TCell(_Symbol, head);
   TCell("เทรดที่ TF", fg, "EA เข้าออเดอร์ตามแท่งของ TF นี้ ไม่ว่ากราฟจะเปิด TF ไหน");
   TCell(TfName(g_tf), fg);
   if((ENUM_TIMEFRAMES)_Period != g_tf)
     {
      TCell("หมายเหตุ", down);
      TCell("กราฟเป็น " + TfName(PERIOD_CURRENT) + " เปลี่ยนเป็น " + TfName(g_tf) + " เพื่อดูป้าย", down);
     }
   TCell("เทรนด์", fg);
   TCell(DirText(g_lastDir), g_lastDir < 0 ? up : g_lastDir > 0 ? down : fg);
   TCell("ออเดอร์ของ EA", fg, "ไม่นับออเดอร์ที่เปิดเองด้วยมือ (แยกด้วย Magic number)");
   TCell(StringFormat("BUY %d (%.2f) · SELL %d (%.2f)", CountPositions(1), OpenLots(1), CountPositions(-1), OpenLots(-1)), fg);
   TCell("ล็อต", fg);
   TCell(LotText(), fg);
   TCell("บัญชี", fg, "Hedging: แยกออเดอร์ตาม TP · Netting: ออเดอร์เดียว EA ปิดบางส่วนที่ TP1/TP2");
   TCell(g_netting ? "Netting" : "Hedging", fg);
   TCell("Magic", fg);
   TCell(IntegerToString((long)g_magic), fg);
   TCell("ตัวกรอง EA", fg, "ตัวกรองที่กำลังหยุดการเข้าออเดอร์ใหม่ (ถ้าเปิดใช้)");
   TCell(g_filterState, g_filterState == "ปกติ" ? up : down);
   TCell("ล่าสุด", fg);
   TCell(last, fg, g_lastEvent);
   TEnd("panel", CORNER_LEFT_UPPER);
  }

double g_resNet[4];
int    g_resWins[4], g_resLosses[4];

// Real results of this EA from the account history (today / week / month / all).
void ComputeResults()
  {
   datetime now = TimeCurrent();
   datetime dayStart = DayStart(now);
   MqlDateTime dt;
   TimeToStruct(dayStart, dt);
   datetime weekStart = (datetime)((long)dayStart - ((dt.day_of_week + 6) % 7) * 86400);
   dt.day = 1;
   datetime monthStart = StructToTime(dt);
   datetime starts[4];
   starts[0] = dayStart;
   starts[1] = weekStart;
   starts[2] = monthStart;
   starts[3] = 0;
   ArrayInitialize(g_resNet, 0.0);
   ArrayInitialize(g_resWins, 0);
   ArrayInitialize(g_resLosses, 0);
   if(HistorySelect(0, now + 86400))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != g_magic || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
            continue;
         datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         double v = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         bool isClose = entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT;
         for(int p = 0; p < 4; p++)
           {
            if(t < starts[p])
               continue;
            g_resNet[p] += v;
            if(isClose)
              {
               if(HistoryDealGetDouble(deal, DEAL_PROFIT) > 0.0)
                  g_resWins[p]++;
               else
                  g_resLosses[p]++;
              }
           }
        }
     }
  }

void DrawResults()
  {
   if(InpResultsMode == DASH_HIDDEN)
     {
      ObjectsDeleteAll(0, g_objPrefix + "Dres_");
      return;
     }
   string names[4] = {"วันนี้", "สัปดาห์นี้", "เดือนนี้", "ทั้งหมด"};
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   color fg = ChartFg();
   color head = C'91,156,246';
   color up = C'8,153,129', down = C'242,54,69';
   string tip = "นับจากประวัติบัญชีจริงของ EA นี้ (Magic เดียวกัน) · กำไรสุทธิหักสเปรด/ค่าคอม/swap แล้ว · ปิดบางส่วนนับเป็นครั้งละ 1";
   if(InpResultsMode == DASH_COMPACT)
     {
      TBegin(2);
      TCell("ผลงาน EA วันนี้", head, tip);
      TCell(StringFormat("%+.2f %s", g_resNet[0], cur), g_resNet[0] >= 0.0 ? up : down);
      TCell("เดือนนี้", fg, tip);
      TCell(StringFormat("%+.2f %s", g_resNet[2], cur), g_resNet[2] >= 0.0 ? up : down);
     }
   else
     {
      TBegin(5);
      TCell("ผลงานจริง EA", head, tip);
      TCell("ปิด", head, "จำนวนครั้งที่ปิดออเดอร์");
      TCell("ชนะ/แพ้", head);
      TCell("อัตราชนะ", head);
      TCell("กำไรสุทธิ " + cur, head);
      for(int p = 0; p < 4; p++)
        {
         int closes = g_resWins[p] + g_resLosses[p];
         TCell(names[p], fg);
         TCell(IntegerToString(closes), fg);
         TCell(IntegerToString(g_resWins[p]) + "/" + IntegerToString(g_resLosses[p]), fg);
         TCell(closes > 0 ? DoubleToString(100.0 * g_resWins[p] / closes, 1) + " %" : "-", fg);
         TCell(StringFormat("%+.2f", g_resNet[p]), g_resNet[p] >= 0.0 ? up : down);
        }
     }
   TEnd("res", InpResultsCorner);
  }

// Small grey text with the SL / TP prices actually sent to the broker.
void DrawSentLevels()
  {
   string pfx = g_objPrefix + "lv_";
   ObjectsDeleteAll(0, pfx);
   if(!InpShowSentLevels)
      return;
   datetime t0 = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t0 == 0)
      return;
   datetime tx = (datetime)((long)t0 + (long)PeriodSeconds() * (InpPriceLabelOffset + 14));
   color clr = Blend(ChartFg(), ChartBg(), 0.45);
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      string key = GvPos(ticket);
      double sp = GvGet(key + "_SP", 0.0);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string comment = PositionGetString(POSITION_COMMENT);
      string tpName = "TP";
      int at = StringFind(comment, "TP");
      if(at >= 0)
         tpName = StringSubstr(comment, at, 3);
      string spText = sp > 0.0 ? " (สเปรด " + Fmt(sp) + ")" : "";
      string items[3];
      double prices[3];
      items[0] = "ส่งจริง SL " + Fmt(sl) + spText;
      prices[0] = sl;
      items[1] = "ส่งจริง " + (g_netting ? "TP" : tpName) + " " + Fmt(tp) + spText;
      prices[1] = tp;
      items[2] = "เข้าจริง " + Fmt(PositionGetDouble(POSITION_PRICE_OPEN));
      prices[2] = PositionGetDouble(POSITION_PRICE_OPEN);
      for(int k = 0; k < 3; k++)
        {
         if(prices[k] <= 0.0)
            continue;
         string name = pfx + DoubleToString(prices[k], _Digits) + "_" + IntegerToString(k);
         if(ObjectFind(0, name) >= 0)
            continue;
         ObjectCreate(0, name, OBJ_TEXT, 0, tx, prices[k]);
         ObjectSetString(0, name, OBJPROP_TEXT, items[k]);
         ObjectSetString(0, name, OBJPROP_FONT, "Tahoma");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         n++;
        }
      if(g_netting)
        {
         double levels[2];
         levels[0] = GvGet(key + "_T1", 0.0);
         levels[1] = GvGet(key + "_T2", 0.0);
         for(int k = 0; k < 2; k++)
           {
            if(levels[k] <= 0.0 || GvGet(key + "_V" + IntegerToString(k + 1), 0.0) <= 0.0)
               continue;
            string name = pfx + "n" + IntegerToString(k);
            ObjectCreate(0, name, OBJ_TEXT, 0, tx, levels[k]);
            ObjectSetString(0, name, OBJPROP_TEXT, "EA ปิดบางส่วน TP" + IntegerToString(k + 1) + " " + Fmt(levels[k]) + spText);
            ObjectSetString(0, name, OBJPROP_FONT, "Tahoma");
            ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
            ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
           }
        }
     }
  }

void RefreshScreen()
  {
   string reasons = "";
   if(InpUseTradeHours && !InTradeHours())
      reasons += "นอกช่วงเวลา; ";
   if(DailyLossReason() != "")
      reasons += "ขาดทุนวันนี้ถึงขีด; ";
   if(InpUseMaxTradesDay && GvGet(GvPrefix() + "N" + IntegerToString(DayNumber()), 0.0) >= InpMaxTradesPerDay)
      reasons += "เทรดครบวันนี้; ";
   if(NewsReason() != "")
      reasons += "ช่วงข่าว; ";
   g_filterState = reasons == "" ? "ปกติ" : "หยุดเข้า: " + reasons;
   ArrayInitialize(g_stack, 0);
   DrawPanel();
   if(InpResultsMode != DASH_HIDDEN && (g_resultsDirty || (long)TimeCurrent() - (long)g_resultsTime >= 60))
     {
      ComputeResults();
      g_resultsDirty = false;
      g_resultsTime = TimeCurrent();
     }
   DrawResults();
   DrawSentLevels();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFactor <= 0.0 || InpAtrPeriod < 1 || InpSlAtrMult <= 0.0 || InpTp1R <= 0.0 || InpTp2R <= 0.0 || InpTp3R <= 0.0
      || InpAdxLength < 1 || InpAdxSmoothing < 1 || InpPivotLength < 1 || InpKeyLevelsCount < 1
      || InpRiskPercent <= 0.0 || InpFixedLots <= 0.0)
     {
      Print("ST TP/SL EA: ค่าที่ตั้งไม่ถูกต้อง (ต้องมากกว่า 0)");
      return INIT_PARAMETERS_INCORRECT;
     }
   int hFrom, hTo;
   if(InpUseTradeHours && !ParseHours(hFrom, hTo))
     {
      Print("ST TP/SL EA: รูปแบบช่วงเวลาไม่ถูกต้อง ต้องเป็น HH:MM-HH:MM เช่น 08:00-22:00");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_tf = InpTradeTf == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTradeTf;
   g_magic = InpMagic > 0 ? InpMagic : AutoMagic();
   g_objPrefix = "STEA" + IntegerToString((long)g_magic) + "_";
   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_netting = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;

   BuildIndicatorParams();
   g_handle = IndicatorCreate(_Symbol, g_tf, IND_CUSTOM, ArraySize(g_params), g_params);
   if(g_handle == INVALID_HANDLE)
     {
      Print("ST TP/SL EA: โหลดอินดิเคเตอร์ไม่ได้ (", GetLastError(), ") ให้ compile Indicators\\ST_TP_SL.mq5 ก่อน แล้ว compile EA ใหม่");
      return INIT_FAILED;
     }
   g_indAdded = false;
   if(InpShowIndicator && (ENUM_TIMEFRAMES)_Period == g_tf && ChartIndicatorAdd(0, 0, g_handle))
     {
      g_indAdded = true;
      g_indName = ChartIndicatorName(0, 0, ChartIndicatorsTotal(0, 0) - 1);
     }
   g_lastBarTime = 0;
   Notify(StringFormat("▶ EA v%s เริ่มทำงาน %s เทรดที่ %s · Magic %I64u · %s", EA_VERSION, _Symbol, TfName(g_tf), g_magic,
                       g_netting ? "Netting" : "Hedging"), false);
   EventSetTimer(5);
   RefreshScreen();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_indAdded && g_indName != "")
      ChartIndicatorDelete(0, 0, g_indName);
   if(g_handle != INVALID_HANDLE)
      IndicatorRelease(g_handle);
   ObjectsDeleteAll(0, g_objPrefix);
   Comment("");
  }

void OnTick()
  {
   ManagePositions();
   datetime barOpen = iTime(_Symbol, g_tf, 0);
   if(barOpen != 0 && barOpen != g_lastBarTime && OnNewSignalBar(barOpen))
     {
      g_lastBarTime = barOpen;
      SweepGlobals();
      RefreshScreen();
     }
  }

void OnTimer()
  {
   RefreshScreen();
  }

// Report SL / TP / stop-out closes done by the broker.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_magic || HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   g_resultsDirty = true;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string what;
   if(reason == DEAL_REASON_TP)
      what = "✅ ถึง TP";
   else
      if(reason == DEAL_REASON_SL)
        {
         what = "🛑 โดน SL";
         GlobalVariableSet(GvPrefix() + "LASTSL", (double)TimeCurrent());
        }
      else
         if(reason == DEAL_REASON_SO)
            what = "⚠ Stop out (มาร์จิ้นไม่พอ)";
         else
            return;   // closes made by this EA are reported where they happen
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                   + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   Notify(StringFormat("%s %s %.2f lot ที่ %s กำไร/ขาดทุน %+.2f %s", what, _Symbol,
                       HistoryDealGetDouble(trans.deal, DEAL_VOLUME), Fmt(HistoryDealGetDouble(trans.deal, DEAL_PRICE)),
                       profit, AccountInfoString(ACCOUNT_CURRENCY)));
  }
//+------------------------------------------------------------------+
