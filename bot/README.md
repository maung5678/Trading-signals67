# บอทแจ้งเตือนสัญญาณ Supertrend (Deriv → มือถือ) ด้วย Termux

บอทนี้ดึงราคาแท่งเทียนจาก Deriv API (ฟรี ไม่ต้องล็อกอิน) คำนวณ Supertrend แบบเดียวกับอินดิเคเตอร์
`ST Alerts v2` (Factor 2.5, ATR 14, SL = 1.5×ATR, TP 1R/2R/3R) แล้วแจ้งเตือนเมื่อมีสัญญาณ LONG/SHORT
บนแท่งที่ **ปิดแล้ว** — ไม่ต้องใช้ TradingView แบบเสียเงิน

- ค่าเริ่มต้น: `BOOM1000` (Boom 1000 Index) timeframe 5 นาที และ 15 นาที
- แจ้งเตือนเด้งในมือถือผ่าน Termux:API และ/หรือ Telegram
- **อ่านราคาอย่างเดียว ไม่เข้าออเดอร์ ไม่ต้องใช้รหัสบัญชีเทรด**

## ติดตั้ง (ครั้งเดียว)

1. ติดตั้งจาก **F-Droid** (https://f-droid.org) ทั้ง 2 แอป:
   - **Termux**
   - **Termux:API** (ใช้เด้งแจ้งเตือน)
   > อย่าใช้ Termux จาก Play Store เพราะเป็นเวอร์ชันเก่าและใช้กับ Termux:API ไม่ได้
2. ดาวน์โหลดไฟล์ `deriv_signal_bot.py` ลงมือถือ (จะอยู่ในโฟลเดอร์ Download)
3. เปิด Termux แล้วพิมพ์ทีละบรรทัด:
   ```bash
   termux-setup-storage
   pkg update -y
   pkg install -y python termux-api
   pip install websocket-client
   mkdir -p ~/bot && cp ~/storage/downloads/deriv_signal_bot.py ~/bot/
   ```
   (`termux-setup-storage` จะถามสิทธิ์เข้าถึงไฟล์ → กด Allow)
4. ตั้งค่าแบตเตอรี่ของโทรศัพท์: Settings → Apps → **Termux** และ **Termux:API**
   → Battery → **Unrestricted / ไม่จำกัด** (ไม่งั้นระบบจะปิดบอทตอนจอดับ)
5. เปิดสิทธิ์ **Notifications** ให้ Termux:API

## ทดสอบ

```bash
cd ~/bot
python deriv_signal_bot.py --test
```

ต้องเห็น: ขีดจำกัด API ของ Deriv, เทรนด์ปัจจุบันของแต่ละ timeframe, สัญญาณล่าสุดในอดีต
และมีแจ้งเตือน "🧪 Test: signal bot is working" เด้งขึ้นมา

> แนะนำ: เทียบ "Last signal" กับกราฟ BOOM_1000_INDEX + ST Alerts v2 บน TradingView (timeframe เดียวกัน)
> ว่าตรงกันก่อนใช้งานจริง

## รันจริง

```bash
cd ~/bot
termux-wake-lock
python deriv_signal_bot.py
```

- ปล่อย Termux ไว้ (กดปุ่ม Home ได้ ไม่ต้องปิด) — จะมีแจ้งเตือน Termux ค้างไว้แปลว่ายังทำงาน
- หยุดบอท: กลับเข้า Termux กด `Ctrl` + `C` แล้ว `termux-wake-unlock`
- ครั้งแรกที่รัน บอทจะไม่แจ้งสัญญาณเก่า — แจ้งเฉพาะแท่งที่ปิด **หลังจาก** เริ่มรัน
- ถ้ามือถือหลับไปแล้วมีสัญญาณระหว่างนั้น จะแจ้งตามหลังพร้อมคำว่า `(late)`

ตัวอย่างแจ้งเตือน:
```
🟢 LONG BOOM1000 [5m]
Entry: 10234.56
SL: 10221.30 (risk 13.26)
TP1: 10247.82
TP2: 10261.08
TP3: 10274.34
Candle close: 07/11 22:15
```

## แดชบอร์ดตั้งค่า (แนะนำ)

ระหว่างบอทรันอยู่ เปิด Chrome บนมือถือเครื่องเดียวกัน ไปที่ **http://127.0.0.1:8765**

- **สถานะ**: เทรนด์ปัจจุบัน เทรดที่กำลังติดตาม (Entry/SL/TP) เวลาเช็กล่าสุด และแจ้งเตือนย้อนหลัง
- **สินทรัพย์ & ไทม์เฟรม**: แตะชิปไทม์เฟรมเพื่อเปิด/ปิด, เลือกว่าจะแจ้ง BUY/SELL, TP1, TP2, TP3, SL
  แยกแต่ละสินทรัพย์, เพิ่ม/ลบสินทรัพย์, เปลี่ยนชื่อที่แสดง (ให้ตรงกับชื่อใน MT5)
- **หน้าตาการแจ้งเตือน**: แบบละเอียด/บรรทัดเดียว, เลือกข้อมูลที่แสดง, อีโมจิ, ความสำคัญ, สีไฟ LED + ตัวอย่างสด
- **เสียง & การสั่น**: เสียงระบบ / พูดออกเสียง (ไทยหรืออังกฤษ) / ไฟล์เสียงของคุณ / ไม่มีเสียง แยกระหว่าง
  BUY/SELL กับ TP/SL, รูปแบบการสั่น
- **Telegram** และ **ค่าการคำนวณ** (Supertrend, ATR, SL, TP R:R, ความถี่เช็กราคา)

กด **💾 บันทึก** แล้วมีผลทันที ไม่ต้องรีสตาร์ทบอท · **🧪 ทดสอบแจ้งเตือน** ส่งตัวอย่างด้วยค่าบนหน้าจอ
แดชบอร์ดเปิดได้เฉพาะจากมือถือเครื่องนี้ (ผูกกับ 127.0.0.1)

> พูดออกเสียงใช้ `termux-tts-speak` ต้องมี Text-to-speech ของ Google ในเครื่อง (ส่วนใหญ่มีอยู่แล้ว)
> ไฟล์เสียงใช้ `termux-media-player` เช่น ใส่ไฟล์ `alert.mp3` ในโฟลเดอร์ Download แล้วกรอก `~/storage/downloads/alert.mp3`

## ตั้งค่าด้วยไฟล์ (แบบเก่า ไม่จำเป็นถ้าใช้แดชบอร์ด)

สร้างไฟล์ `~/bot/config.json` (ดูตัวอย่างใน `config.example.json`) แล้วใส่เฉพาะค่าที่ต้องการเปลี่ยน เช่น:

```json
{
  "symbols": ["BOOM1000", "CRASH1000"],
  "timeframes_minutes": [5, 15],
  "telegram_bot_token": "123456:ABC...",
  "telegram_chat_id": "123456789"
}
```

| ค่า | ความหมาย |
|---|---|
| `watchlist` | กำหนด timeframe แยกตามสินทรัพย์ เช่น `[{"symbol": "cryBTCUSD", "timeframes": [1]}]` (ถ้ามี จะใช้แทน `symbols`/`timeframes_minutes`) |
| `symbols` + `timeframes_minutes` | แบบง่าย: ทุกสินทรัพย์ × ทุก timeframe. Timeframe: 1, 2, 3, 5, 10, 15, 30, 60, 120, 240, 480, 1440 |
| `supertrend_factor`, `atr_period`, `sl_atr_mult`, `tp_rr` | ให้ตรงกับ Settings ของอินดิเคเตอร์ |
| `poll_seconds` | เช็กราคาทุกกี่วินาที (ค่าเริ่มต้น 20 — ต่ำกว่าขีดจำกัด Deriv: 220 ครั้ง/นาที, 14,400 ครั้ง/ชม.) |
| `notify_tp_sl` | แจ้งเมื่อถึง TP1/TP2/TP3 หรือโดน SL |
| `notify_termux` | เด้งแจ้งเตือนในมือถือผ่าน Termux:API |
| `telegram_bot_token`, `telegram_chat_id` | ส่งเข้า Telegram ด้วย (ดูวิธีขอใน README หลัก) |
| `deriv_app_id` | ค่าเริ่มต้น `1089` (app_id สาธารณะ) — ถ้าใช้ไม่ได้ ให้สมัครของตัวเองฟรีที่ api.deriv.com |
| `deriv_ws_urls` | รายการเซิร์ฟเวอร์ Deriv ที่ลองตามลำดับ (บางตัวตอบ error 520 — บอทสลับให้เอง) |

## รหัสสินทรัพย์ที่ใช้ได้ (ทดสอบกับ Deriv API แล้ว)

| ใน config | ชื่อใน MT5 / TradingView |
|---|---|
| `BOOM1000`, `BOOM500`, `BOOM300N` | Boom 1000 / 500 / 300 Index |
| `CRASH1000`, `CRASH500`, `CRASH300N` | Crash 1000 / 500 / 300 Index |
| `R_10`, `R_75`, `R_100` | Volatility 10 / 75 / 100 Index |
| `1HZ75V`, `1HZ100V` | Volatility 75 (1s) / 100 (1s) Index |
| `stpRNG` | Step Index |
| `JD25` | Jump 25 Index |
| `frxXAUUSD`, `frxEURUSD` | Gold/USD, EUR/USD |
| `cryBTCUSD` | BTC/USD |

## ข้อจำกัด

- สัญญาณมาจาก Supertrend flip เท่านั้น (ค่าเริ่มต้นของอินดิเคเตอร์) — ฟิลเตอร์เสริม เช่น ADX / EMA200 /
  breakout / re-entry ยังไม่ได้ใส่ในบอท
- SL แจ้งเฉพาะกรณีโดน SL ก่อนถึง TP1 (เหมือนสถิติในอินดิเคเตอร์)
- ราคา Deriv API ควรตรงกับ MT5 ของ Deriv แต่อาจต่างจากกราฟ TradingView เล็กน้อย
