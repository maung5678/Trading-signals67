# Supertrend with Entry, TP1–TP3 & SL — ฉบับปรับแต่ง

ไฟล์อินดิเคเตอร์: [`indicators/ST_with_TP_SL.pine`](indicators/ST_with_TP_SL.pine)
(คัดลอกทั้งไฟล์ไปวางใน Pine Editor ของ TradingView แล้วกด **Add to chart**)

EA สำหรับ MT5 (เปิดออเดอร์อัตโนมัติพร้อม SL / TP1–TP3): [`mt5/ST_TP_SL_EA.mq5`](mt5/ST_TP_SL_EA.mq5)
วิธีติดตั้งและตั้งค่า: [`mt5/README.md`](mt5/README.md)

## 1. ซ่อน / ย่อ แดชบอร์ด

เปิด **Settings (⚙️) → Inputs → กลุ่ม "Dashboards (hide / compact)"**

| ตัวเลือก | ความหมาย |
|---|---|
| **Hide ALL dashboards** | ติ๊กช่องเดียว ซ่อนทุกตารางบนกราฟ |
| **Show Telegram banner** | แบนเนอร์ "Join Telegram" ด้านบน (ค่าเริ่มต้น: ปิด) |
| **Dashboard text size** | ขนาดตัวอักษรของทุกตาราง (tiny / small / normal) |
| **Win-rate statistics** | Full / Compact (แค่ Win rate + Profit) / Hidden |
| **ADX dashboard** | Full / Compact (ADX + สถานะ Filter บรรทัดเดียว) / Hidden |
| **Multi-timeframe dashboard** | Full / Compact (แถวเดียว `5m ▲ 15m ▲ 1h ▼ …`) / Hidden |
| **Trade history** | Full (10 เทรด) / Compact (3 เทรด) / Hidden |

แต่ละตารางเลือก **ตำแหน่งบนจอ** ได้จากดรอปดาวน์ข้าง ๆ (top_right, bottom_left ฯลฯ)

> หมายเหตุ: Pine Script ไม่รองรับการคลิกที่ตารางเพื่อยุบ/ขยาย จึงทำเป็นตัวเลือกใน Settings แทน
> ถ้าต้องการสลับบ่อย ๆ ให้บันทึกเป็น Template: Settings → ปุ่ม **Defaults → Save as…**

## 2. แจ้งเตือนสัญญาณใหม่

ตั้งค่าในกลุ่ม **"Notifications (LINE / Telegram)"**: เลือกได้ว่าจะแจ้งเตือนเมื่อ
สัญญาณ BUY/SELL ใหม่, ถึง TP1/TP2/TP3, หรือโดน SL

ตัวอย่างข้อความที่ได้รับ:

```
🟢 LONG (Buy) XAUUSD [15]
Entry: 2650.35
SL: 2641.20 (risk 9.15)
TP1: 2659.50
TP2: 2668.65
TP3: 2677.80
Time: 07/11 14:30
```

### ใช้งานจริง: รับแจ้งเตือนบนมือถือ แล้วเข้าออเดอร์เองใน MT4/MT5

- **ไม่ต้องเปิดคอมหรือแอปค้างไว้**: Alert รันบนเซิร์ฟเวอร์ TradingView ตลอด 24 ชม.
- โทรศัพท์ได้ push notification แม้ปิดแอปอยู่ (เปิดสิทธิ์แจ้งเตือนของแอป TradingView/Telegram ไว้)
- เมื่อได้รับ: เปิดแอป MT5 → New order → เลือก Buy (LONG) หรือ Sell (SHORT)
  → ใส่ **Stop Loss** และ **Take Profit** (TP1/TP2/TP3 ตามที่ต้องการ) จากข้อความ
- ชื่อสัญลักษณ์ใน MT อาจต่างจาก TradingView เช่น `XAUUSD` vs `XAUUSDm` และราคาโบรกอาจต่างเล็กน้อย
  ควรใช้กราฟของโบรกเดียวกันบน TradingView ถ้ามี (เช่น `OANDA:XAUUSD`, `EXNESS:XAUUSD`)
- แพ็กเกจฟรีของ TradingView มีจำนวน Alert และระยะเวลาหมดอายุจำกัด: ตรวจที่หน้า Alerts ว่ายัง Active

### สร้าง Alert ใน TradingView (ทำครั้งเดียวต่อกราฟ)

1. กด **Alert (⏰)** → Condition: เลือก **ST Alerts v2** → **Any alert() function call**
2. Expiration: ตั้งเป็น Open-ended (ถ้าแพ็กเกจรองรับ)
3. แท็บ **Notifications** เลือกช่องทางตามด้านล่าง → **Create**

> แจ้งเตือนจะส่งเมื่อ **แท่งเทียนปิด** เท่านั้น เพื่อกันสัญญาณหลอกระหว่างแท่ง
> ถ้าเปลี่ยน Settings ของอินดิเคเตอร์ ต้องลบ Alert เดิมแล้วสร้างใหม่

### ทางเลือก A — แอป TradingView บนมือถือ (ง่ายสุด, ฟรี)
ติ๊ก **Notify in app** แล้วล็อกอินแอป TradingView บนมือถือ จะได้ push notification ทันที

### ทางเลือก B — Telegram (ต้องใช้ Webhook = แพ็กเกจ Essential ขึ้นไป)
1. ใน Telegram คุยกับ **@BotFather** → `/newbot` → ได้ **Bot Token** เช่น `123456:ABC-xyz`
2. ส่งข้อความอะไรก็ได้หาบอทของคุณ 1 ครั้ง แล้วเปิด
   `https://api.telegram.org/bot<TOKEN>/getUpdates` ในเบราว์เซอร์ → หา `"chat":{"id": ...}` นั่นคือ **chat_id**
   (ถ้าเป็นกลุ่ม ให้เชิญบอทเข้ากลุ่มก่อน chat_id จะขึ้นต้นด้วย `-100…`)
3. ใน Settings อินดิเคเตอร์: Message format = **Telegram JSON (webhook)** และใส่ **Telegram chat_id**
4. ตอนสร้าง Alert ติ๊ก **Webhook URL** แล้วใส่
   `https://api.telegram.org/bot<TOKEN>/sendMessage`

### ทางเลือก C — LINE (ต้องใช้ Webhook + ตัวกลาง Google Apps Script ฟรี)
LINE Notify ปิดบริการไปแล้ว (31 มี.ค. 2025) และ LINE Messaging API ต้องใส่ header ที่ TradingView ใส่ให้ไม่ได้
จึงต้องมีตัวกลาง [`relay/line_relay.gs`](relay/line_relay.gs):

1. [LINE Developers](https://developers.line.biz/) → สร้าง Provider → **Messaging API channel**
   - แท็บ Messaging API → ออก **Channel access token (long-lived)**
   - แท็บ Basic settings → คัดลอก **Your user ID** (ขึ้นต้นด้วย `U…`)
   - สแกน QR เพิ่มบอทเป็นเพื่อนใน LINE
2. ไปที่ [script.google.com](https://script.google.com) → New project → วางโค้ดจาก `relay/line_relay.gs`
3. Project Settings → **Script properties** เพิ่ม
   `LINE_CHANNEL_ACCESS_TOKEN`, `LINE_TO` (user ID), `SHARED_SECRET` (คำลับอะไรก็ได้)
4. **Deploy → New deployment → Web app**, Execute as: *Me*, Who has access: *Anyone* → คัดลอก URL
5. ใน Settings อินดิเคเตอร์: Message format = **Text**
6. ตอนสร้าง Alert ติ๊ก **Webhook URL** แล้วใส่ `https://script.google.com/macros/s/…/exec?key=<SHARED_SECRET>`

## สิ่งที่เปลี่ยนจากต้นฉบับ
- เพิ่มกลุ่มตั้งค่า Dashboards: Hide all / Full / Compact / Hidden / ตำแหน่ง / ขนาดตัวอักษร
- แบนเนอร์ Telegram ซ่อนได้ (ค่าเริ่มต้นซ่อน)
- เพิ่มแจ้งเตือนผ่าน `alert()` พร้อมราคา Entry / SL / TP1–TP3 รองรับ JSON ของ Telegram
- เพิ่ม `alertcondition` "Stop loss hit"
- ตรรกะการคำนวณสัญญาณ / TP / SL **ไม่ได้แก้ไข**
