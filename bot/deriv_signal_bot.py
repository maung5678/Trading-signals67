#!/usr/bin/env python3
"""
Deriv Supertrend signal bot (for Termux on Android, or any machine with Python 3).

Replicates the signal logic of indicators/ST_with_TP_SL.pine with default settings:
  - Supertrend(factor, ATR period) on hl2, same as TradingView ta.supertrend
  - BUY  (LONG)  when the direction flips to uptrend on a CLOSED candle
  - SELL (SHORT) when the direction flips to downtrend on a CLOSED candle
  - SL = entry -/+ ATR * sl_atr_mult, TP1/TP2/TP3 = 1R / 2R / 3R
Then sends a notification to Telegram and/or the Android notification bar (Termux:API).

Only reads public market data. It never logs in to a trading account and never places orders.

Usage:
  python deriv_signal_bot.py            # run forever
  python deriv_signal_bot.py --test     # send a test message, print latest state, exit
"""
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

try:
    import websocket  # pip install websocket-client
except ImportError:  # pragma: no cover
    websocket = None

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
STATE_PATH = os.path.join(HERE, "state.json")

DEFAULT_CONFIG = {
    "deriv_app_id": "1089",
    "deriv_ws_url": "wss://ws.derivws.com/websockets/v3",
    "symbols": ["BOOM1000"],
    "timeframes_minutes": [5, 15],
    "supertrend_factor": 2.5,
    "atr_period": 14,
    "sl_atr_mult": 1.5,
    "tp_rr": [1.0, 2.0, 3.0],
    "candles": 300,
    "poll_seconds": 20,
    "notify_termux": True,
    "telegram_bot_token": "",
    "telegram_chat_id": "",
    "notify_tp_sl": True,
    "timezone_offset_hours": 7,
}


# ---------------------------------------------------------------------------
# Indicator math (mirrors TradingView ta.atr / ta.supertrend)
# ---------------------------------------------------------------------------
def atr_rma(highs, lows, closes, period):
    """ATR using Wilder's RMA, seeded with an SMA of the first `period` true ranges."""
    n = len(closes)
    tr = [None] * n
    for i in range(n):
        if i == 0:
            tr[i] = highs[i] - lows[i]
        else:
            tr[i] = max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1]))
    atr = [None] * n
    if n < period:
        return atr
    atr[period - 1] = sum(tr[:period]) / period
    for i in range(period, n):
        atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return atr


def supertrend(highs, lows, closes, factor, period):
    """Returns (supertrend, direction, atr). direction: -1 = uptrend, 1 = downtrend (TradingView convention)."""
    n = len(closes)
    atr = atr_rma(highs, lows, closes, period)
    st = [None] * n
    direction = [None] * n
    upper_prev = lower_prev = st_prev = None
    for i in range(n):
        if atr[i] is None:
            continue
        src = (highs[i] + lows[i]) / 2.0
        upper = src + factor * atr[i]
        lower = src - factor * atr[i]
        p_lower = lower_prev if lower_prev is not None else 0.0
        p_upper = upper_prev if upper_prev is not None else 0.0
        prev_close = closes[i - 1] if i > 0 else closes[i]
        lower = lower if (lower > p_lower or prev_close < p_lower) else p_lower
        upper = upper if (upper < p_upper or prev_close > p_upper) else p_upper
        if i == 0 or atr[i - 1] is None:
            d = 1
        elif st_prev == upper_prev:
            d = -1 if closes[i] > upper else 1
        else:
            d = 1 if closes[i] < lower else -1
        st[i] = lower if d == -1 else upper
        direction[i] = d
        upper_prev, lower_prev, st_prev = upper, lower, st[i]
    return st, direction, atr


def signal_at(direction, i):
    """'LONG' / 'SHORT' if the Supertrend direction flipped on candle i, else None."""
    if i < 1 or direction[i] is None or direction[i - 1] is None:
        return None
    if direction[i] < 0 <= direction[i - 1]:
        return "LONG"
    if direction[i] > 0 >= direction[i - 1]:
        return "SHORT"
    return None


def make_trade(side, candle, atr_value, cfg):
    entry = candle["close"]
    risk = atr_value * cfg["sl_atr_mult"]
    sign = 1 if side == "LONG" else -1
    return {
        "side": side,
        "epoch": candle["epoch"],
        "entry": entry,
        "sl": entry - sign * risk,
        "tps": [entry + sign * risk * rr for rr in cfg["tp_rr"]],
        "tp_hit": [False] * len(cfg["tp_rr"]),
        "closed": False,
    }


def update_trade(trade, candle):
    """Check TP/SL on a newly closed candle. Returns list of event strings."""
    events = []
    if trade is None or trade["closed"] or candle["epoch"] <= trade["epoch"]:
        return events
    long_side = trade["side"] == "LONG"
    sl_hit = candle["low"] <= trade["sl"] if long_side else candle["high"] >= trade["sl"]
    for k, tp in enumerate(trade["tps"]):
        if not trade["tp_hit"][k] and (candle["high"] >= tp if long_side else candle["low"] <= tp):
            trade["tp_hit"][k] = True
            events.append("TP%d" % (k + 1))
    if sl_hit and not any(trade["tp_hit"]):
        events.append("SL")
        trade["closed"] = True
    if all(trade["tp_hit"]):
        trade["closed"] = True
    return events


# ---------------------------------------------------------------------------
# Deriv API
# ---------------------------------------------------------------------------
class Deriv:
    def __init__(self, cfg):
        self.url = "%s?app_id=%s" % (cfg["deriv_ws_url"], cfg["deriv_app_id"])
        self.ws = None

    def _conn(self):
        if self.ws is None:
            self.ws = websocket.create_connection(self.url, timeout=30)
        return self.ws

    def call(self, payload):
        try:
            ws = self._conn()
            ws.send(json.dumps(payload))
            resp = json.loads(ws.recv())
        except Exception:
            self.close()
            raise
        if "error" in resp:
            raise RuntimeError("Deriv API error: %s" % resp["error"].get("message"))
        return resp

    def close(self):
        try:
            if self.ws is not None:
                self.ws.close()
        finally:
            self.ws = None

    def closed_candles(self, symbol, granularity, count):
        resp = self.call({
            "ticks_history": symbol, "style": "candles", "granularity": granularity,
            "count": count, "end": "latest", "adjust_start_time": 1,
        })
        candles = [
            {"epoch": int(c["epoch"]), "open": float(c["open"]), "high": float(c["high"]),
             "low": float(c["low"]), "close": float(c["close"])}
            for c in resp.get("candles", [])
        ]
        now = time.time()
        # Drop the still-forming candle (its close time is in the future).
        return [c for c in candles if c["epoch"] + granularity <= now]

    def api_limits(self):
        try:
            return self.call({"website_status": 1}).get("website_status", {}).get("api_call_limits")
        except Exception as exc:  # informational only
            return "unavailable (%s)" % exc


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
def notify(cfg, title, body):
    print("\n=== %s ===\n%s\n" % (title, body), flush=True)
    if cfg.get("telegram_bot_token") and cfg.get("telegram_chat_id"):
        try:
            data = urllib.parse.urlencode({"chat_id": cfg["telegram_chat_id"], "text": title + "\n" + body}).encode()
            url = "https://api.telegram.org/bot%s/sendMessage" % cfg["telegram_bot_token"]
            urllib.request.urlopen(url, data=data, timeout=20).read()
        except Exception as exc:
            print("Telegram send failed: %s" % exc, flush=True)
    if cfg.get("notify_termux"):
        try:
            subprocess.run(
                ["termux-notification", "--title", title, "--content", body, "--priority", "max",
                 "--sound", "--vibrate", "500,200,500", "--id", str(int(time.time()) % 100000)],
                check=False, timeout=20,
            )
        except FileNotFoundError:
            pass  # Termux:API not installed; console/Telegram only
        except Exception as exc:
            print("Termux notification failed: %s" % exc, flush=True)


def fmt(price):
    return ("%.4f" % price).rstrip("0").rstrip(".")


def fmt_time(epoch, cfg):
    return time.strftime("%d/%m %H:%M", time.gmtime(epoch + cfg["timezone_offset_hours"] * 3600))


def signal_message(symbol, tf, trade, granularity, cfg):
    icon = "🟢" if trade["side"] == "LONG" else "🔴"
    title = "%s %s %s [%dm]" % (icon, trade["side"], symbol, tf)
    lines = ["Entry: %s" % fmt(trade["entry"]),
             "SL: %s (risk %s)" % (fmt(trade["sl"]), fmt(abs(trade["entry"] - trade["sl"])))]
    lines += ["TP%d: %s" % (k + 1, fmt(tp)) for k, tp in enumerate(trade["tps"])]
    lines.append("Candle close: %s" % fmt_time(trade["epoch"] + granularity, cfg))
    return title, "\n".join(lines)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


def load_state():
    if os.path.exists(STATE_PATH):
        try:
            with open(STATE_PATH, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_PATH)


def process(deriv, cfg, state, symbol, tf):
    key = "%s_%d" % (symbol, tf)
    gran = tf * 60
    candles = deriv.closed_candles(symbol, gran, cfg["candles"])
    if len(candles) < cfg["atr_period"] + 2:
        return
    st = state.setdefault(key, {"last_epoch": 0, "trade": None})
    if candles[-1]["epoch"] <= st["last_epoch"]:
        return  # no new closed candle yet
    first_run = st["last_epoch"] == 0
    highs = [c["high"] for c in candles]
    lows = [c["low"] for c in candles]
    closes = [c["close"] for c in candles]
    _, direction, atr = supertrend(highs, lows, closes, cfg["supertrend_factor"], cfg["atr_period"])

    # Walk every candle that closed since the last check (the phone may have slept).
    for i, candle in enumerate(candles):
        if candle["epoch"] <= st["last_epoch"]:
            continue
        side = signal_at(direction, i)
        if side:
            st["trade"] = make_trade(side, candle, atr[i], cfg)
            if not first_run:
                title, body = signal_message(symbol, tf, st["trade"], gran, cfg)
                if i < len(candles) - 1:
                    title += " (late)"
                notify(cfg, title, body)
            continue
        if cfg.get("notify_tp_sl") and not first_run:
            for ev in update_trade(st["trade"], candle):
                t = st["trade"]
                if ev == "SL":
                    notify(cfg, "⛔ SL hit %s [%dm]" % (symbol, tf), "SL: %s" % fmt(t["sl"]))
                else:
                    k = int(ev[2:]) - 1
                    notify(cfg, "✅ %s reached %s [%dm]" % (ev, symbol, tf), "%s: %s" % (ev, fmt(t["tps"][k])))
    st["last_epoch"] = candles[-1]["epoch"]
    print("%s %s [%dm] checked candle %s" % (time.strftime("%H:%M:%S"), symbol, tf, fmt_time(candles[-1]["epoch"], cfg)), flush=True)


def run_test(cfg):
    deriv = Deriv(cfg)
    print("Deriv API limits:", json.dumps(deriv.api_limits(), indent=1))
    for symbol in cfg["symbols"]:
        for tf in cfg["timeframes_minutes"]:
            gran = tf * 60
            candles = deriv.closed_candles(symbol, gran, cfg["candles"])
            highs = [c["high"] for c in candles]
            lows = [c["low"] for c in candles]
            closes = [c["close"] for c in candles]
            _, direction, atr = supertrend(highs, lows, closes, cfg["supertrend_factor"], cfg["atr_period"])
            last_sig = None
            for i in range(1, len(candles)):
                if direction[i] is None or direction[i - 1] is None:
                    continue
                if direction[i] != direction[i - 1]:
                    last_sig = make_trade("LONG" if direction[i] < 0 else "SHORT", candles[i], atr[i], cfg)
            trend = "UP" if direction[-1] == -1 else "DOWN"
            print("%s [%dm]: %d candles, trend now %s, close %s" % (symbol, tf, len(candles), trend, fmt(closes[-1])))
            if last_sig:
                title, body = signal_message(symbol, tf, last_sig, gran, cfg)
                print("  Last signal (history):", title.replace("\n", " "), "|", body.replace("\n", " | "))
    deriv.close()
    notify(cfg, "🧪 Test: signal bot is working", "If you see this, notifications are set up correctly.")


def main():
    if websocket is None:
        sys.exit("Missing package. Run:  pip install websocket-client")
    cfg = load_config()
    if "--test" in sys.argv:
        run_test(cfg)
        return
    state = load_state()
    deriv = Deriv(cfg)
    print("Bot started. Symbols=%s timeframes=%s min. Ctrl+C to stop." % (cfg["symbols"], cfg["timeframes_minutes"]), flush=True)
    backoff = 5
    while True:
        try:
            for symbol in cfg["symbols"]:
                for tf in cfg["timeframes_minutes"]:
                    process(deriv, cfg, state, symbol, tf)
            save_state(state)
            backoff = 5
            time.sleep(cfg["poll_seconds"])
        except KeyboardInterrupt:
            print("Stopped.")
            break
        except Exception as exc:
            print("%s error: %s (retry in %ds)" % (time.strftime("%H:%M:%S"), exc, backoff), flush=True)
            deriv.close()
            time.sleep(backoff)
            backoff = min(backoff * 2, 300)


if __name__ == "__main__":
    main()
