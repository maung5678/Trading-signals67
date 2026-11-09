#!/usr/bin/env python3
"""
Deriv Supertrend signal bot with a built-in settings dashboard.
Made for Termux on Android, works on any machine with Python 3.8+.

Signal logic mirrors indicators/ST_with_TP_SL.pine (default settings):
  - Supertrend(factor, ATR period) on hl2, same as TradingView ta.supertrend
  - BUY (Long) / SELL (Short) when the direction flips on a CLOSED candle
  - SL = entry -/+ ATR * sl_atr_mult, TP1/TP2/TP3 = entry +/- risk * tp_rr

It only reads public market data. It never logs in to a trading account and never places orders.

Usage:
  python deriv_signal_bot.py              # run bot + dashboard at http://127.0.0.1:8765
  python deriv_signal_bot.py --test       # check data + send a test notification, then exit
  python deriv_signal_bot.py --no-dashboard
"""
import copy
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import websocket  # pip install websocket-client
except ImportError:  # pragma: no cover
    websocket = None

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
STATE_PATH = os.path.join(HERE, "state.json")
LOG_PATH = os.path.join(HERE, "log.json")  # recent notifications, shown in the dashboard

# Deriv candle granularities, in minutes.
TIMEFRAMES = [1, 2, 3, 5, 10, 15, 30, 60, 120, 240, 480, 1440]

# Symbols verified against the Deriv API. Label = name to look for in MT5.
KNOWN_SYMBOLS = {
    "cryBTCUSD": "BTCUSD",
    "CRASH1000": "Crash 1000 Index",
    "BOOM1000": "Boom 1000 Index",
    "CRASH500": "Crash 500 Index",
    "BOOM500": "Boom 500 Index",
    "CRASH300N": "Crash 300 Index",
    "BOOM300N": "Boom 300 Index",
    "R_10": "Volatility 10 Index",
    "R_75": "Volatility 75 Index",
    "R_100": "Volatility 100 Index",
    "1HZ75V": "Volatility 75 (1s) Index",
    "1HZ100V": "Volatility 100 (1s) Index",
    "stpRNG": "Step Index",
    "JD25": "Jump 25 Index",
    "frxXAUUSD": "XAUUSD",
    "frxEURUSD": "EURUSD",
}

DEFAULT_ALERTS = {"signal": True, "tp1": True, "tp2": True, "tp3": True, "sl": True}

DEFAULT_CONFIG = {
    "assets": [
        {"symbol": "cryBTCUSD", "label": "BTCUSD", "enabled": True, "timeframes": [1], "confirm_tf": 0, "alerts": dict(DEFAULT_ALERTS)},
        {"symbol": "CRASH1000", "label": "Crash 1000 Index", "enabled": True, "timeframes": [15], "confirm_tf": 0, "alerts": dict(DEFAULT_ALERTS)},
        {"symbol": "BOOM1000", "label": "Boom 1000 Index", "enabled": True, "timeframes": [15], "confirm_tf": 0, "alerts": dict(DEFAULT_ALERTS)},
    ],
    "strategy": {
        "supertrend_factor": 2.5, "atr_period": 14, "sl_atr_mult": 1.5, "tp_rr": [1.0, 2.0, 3.0],
        # Same as the indicator's "สัญญาณเฉพาะตอน ADX แรง" + "เกณฑ์ ADX ของสัญญาณ".
        "adx_filter": False, "adx_min": 25.0, "adx_length": 14, "adx_smoothing": 14,
    },
    "notify": {
        "termux": True,
        "style": "detailed",  # detailed | compact
        "emoji": True,
        "fields": {"entry": True, "sl": True, "risk": True, "tp1": True, "tp2": True, "tp3": True, "time": True},
        "priority": "max",  # max | high | default | low
        "vibrate": "500,200,500",  # "" = no vibration
        "led_color": "00ff00",
        "signal_sound": "system",  # system | tts | file | none
        "tpsl_sound": "system",
        "sound_file": "",
        "tts_lang": "th",  # th | en
        "telegram": False,
        "telegram_bot_token": "",
        "telegram_chat_id": "",
    },
    "poll_seconds": 20,
    "candles": 300,
    # Win-rate statistics count trades entered in the last N days (same as the indicator's
    # "นับสถิติย้อนหลัง (วัน)"). Deriv returns at most 5000 candles, so 1m charts reach ~3.5 days.
    "stats_days": 7,
    "timezone_offset_hours": 7,
    "dashboard_port": 8765,
    "deriv_app_id": "1089",
    # Tried in order; the bot switches to the next one when a server refuses the connection.
    "deriv_ws_urls": [
        "wss://red.derivws.com/websockets/v3",
        "wss://ws.derivws.com/websockets/v3",
        "wss://green.derivws.com/websockets/v3",
        "wss://blue.derivws.com/websockets/v3",
        "wss://ws.binaryws.com/websockets/v3",
    ],
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


def rma(values, period):
    """TradingView ta.rma: seeded with an SMA once `period` non-empty values exist."""
    out = [None] * len(values)
    prev = None
    for i, v in enumerate(values):
        if prev is None:
            window = values[max(0, i - period + 1): i + 1]
            if len(window) == period and all(x is not None for x in window):
                prev = sum(window) / period
        elif v is not None:
            prev = (prev * (period - 1) + v) / period
        out[i] = prev
    return out


def adx_dmi(highs, lows, closes, length, smoothing):
    """TradingView ta.dmi(length, smoothing) -> (+DI, -DI, ADX) lists."""
    n = len(closes)
    tr, plus_dm, minus_dm = [None] * n, [None] * n, [None] * n
    for i in range(n):
        if i == 0:
            tr[i] = highs[i] - lows[i]
            continue
        tr[i] = max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1]))
        up, down = highs[i] - highs[i - 1], lows[i - 1] - lows[i]
        plus_dm[i] = up if (up > down and up > 0) else 0.0
        minus_dm[i] = down if (down > up and down > 0) else 0.0
    trur, p_s, m_s = rma(tr, length), rma(plus_dm, length), rma(minus_dm, length)
    plus, minus, dx = [None] * n, [None] * n, [None] * n
    for i in range(n):
        if trur[i] and p_s[i] is not None and m_s[i] is not None:
            plus[i] = 100.0 * p_s[i] / trur[i]
            minus[i] = 100.0 * m_s[i] / trur[i]
            total = plus[i] + minus[i]
            dx[i] = abs(plus[i] - minus[i]) / (total if total != 0 else 1.0)
    adx = [None if v is None else 100.0 * v for v in rma(dx, smoothing)]
    return plus, minus, adx


def signal_at(direction, i):
    """'LONG' / 'SHORT' if the Supertrend direction flipped on candle i, else None."""
    if i < 1 or direction[i] is None or direction[i - 1] is None:
        return None
    if direction[i] < 0 <= direction[i - 1]:
        return "LONG"
    if direction[i] > 0 >= direction[i - 1]:
        return "SHORT"
    return None


def price_digits(candles):
    """Decimal places used by this market's prices (e.g. 3 for 75760.372)."""
    best = 0
    for c in candles[-20:]:
        txt = repr(c["close"])
        if "." in txt and "e" not in txt:
            best = max(best, len(txt.split(".")[1]))
    return min(best, 6)


def make_trade(side, candle, atr_value, strategy, digits=5):
    entry = candle["close"]
    risk = atr_value * strategy["sl_atr_mult"]
    sign = 1 if side == "LONG" else -1
    return {
        "side": side,
        "epoch": candle["epoch"],
        "entry": entry,
        "sl": entry - sign * risk,
        "tps": [entry + sign * risk * rr for rr in strategy["tp_rr"]],
        "tp_hit": [False] * len(strategy["tp_rr"]),
        "closed": False,
        "digits": digits,
    }


def update_trade(trade, candle):
    """Check TP/SL on a newly closed candle. Returns list of events: 'TP1'.., 'SL'."""
    events = []
    if trade is None or trade["closed"] or candle["epoch"] <= trade["epoch"]:
        return events
    long_side = trade["side"] == "LONG"
    sl_hit = candle["low"] <= trade["sl"] if long_side else candle["high"] >= trade["sl"]
    if sl_hit:
        # Same rule as the indicator: SL is checked first. After TP1 it means "came back to SL".
        events.append("SL_AFTER_TP" if any(trade["tp_hit"]) else "SL")
        trade["closed"] = True
        return events
    for k, tp in enumerate(trade["tps"]):
        if not trade["tp_hit"][k] and (candle["high"] >= tp if long_side else candle["low"] <= tp):
            trade["tp_hit"][k] = True
            events.append("TP%d" % (k + 1))
    if all(trade["tp_hit"]):
        trade["closed"] = True
    return events


def backtest(candles, direction, atr, strategy, allowed=None, history_size=10, since_epoch=0):
    """Win-rate statistics, counted exactly like the indicator's "สถิติย้อนหลัง" table:
    - TP1 before SL = win (+TP1 R), SL before TP1 = loss (-1R)
    - an opposite signal before either = closed at that candle's close (win/loss by its real R)
    - history keeps the best TP reached ("TP2", "TP1→SL", "REV" ...), newest first.
    `allowed(i, side)` returns False for signals removed by the filters.
    Only trades entered at or after `since_epoch` are counted (earlier candles just warm up)."""
    rr = strategy["tp_rr"]
    st = {"signals": 0, "wins": 0, "losses": 0, "profit_r": 0.0}
    hist = []
    t = None  # open trade: side, dir, entry, sl, tps, reached, resolved, recorded, epoch

    def count(field, r):
        if t["epoch"] >= since_epoch:
            st[field] += 1
            st["profit_r"] += r

    def record(outcome, r, sl_hit):
        if not t["recorded"] and t["epoch"] >= since_epoch:
            hist.insert(0, {"side": t["side"], "outcome": outcome, "r": round(r, 2), "sl": sl_hit, "epoch": t["epoch"]})
            del hist[history_size:]
            t["recorded"] = True

    for i, c in enumerate(candles):
        side = signal_at(direction, i)
        if side and allowed is not None and not allowed(i, side):
            side = None
        if t is not None and t["dir"] != 0:
            d = t["dir"]
            sl_hit = c["low"] <= t["sl"] if d == 1 else c["high"] >= t["sl"]
            # 1) stats: SL first, then TP1
            if not t["resolved"]:
                if sl_hit:
                    count("losses", -1.0)
                    record("SL", -1.0, True)
                    t["resolved"] = True
                    t["dir"] = 0
                elif (c["high"] >= t["tps"][0] if d == 1 else c["low"] <= t["tps"][0]):
                    count("wins", rr[0])
                    t["resolved"] = True
            # 2) came back to SL after TP1
            if t["dir"] != 0 and t["reached"][0] and sl_hit:
                best = max(k for k in range(3) if t["reached"][k])
                record("TP%d→SL" % (best + 1), rr[best], True)
                t["dir"] = 0
            # 3) mark TPs
            if t["dir"] != 0:
                for k in range(3):
                    if not t["reached"][k] and (c["high"] >= t["tps"][k] if d == 1 else c["low"] <= t["tps"][k]):
                        t["reached"][k] = True
                if t["reached"][2]:
                    record("TP3", rr[2], False)
        if side and t is not None and t["dir"] != 0:
            # 4) opposite signal closes the previous trade
            risk = abs(t["entry"] - t["sl"])
            rev_r = (c["close"] - t["entry"]) * t["dir"] / risk if risk > 0 else 0.0
            if not t["resolved"]:
                count("wins" if rev_r > 0 else "losses", rev_r)
                t["resolved"] = True
            best = max([k for k in range(3) if t["reached"][k]] or [-1])
            record("TP%d" % (best + 1) if best >= 0 else "REV", rr[best] if best >= 0 else rev_r, False)
        if side:
            tr = make_trade(side, c, atr[i], strategy)
            t = {"side": side, "dir": 1 if side == "LONG" else -1, "entry": tr["entry"], "sl": tr["sl"],
                 "tps": tr["tps"], "reached": [False] * 3, "resolved": False, "recorded": False, "epoch": c["epoch"]}
            st["signals"] += 1 if c["epoch"] >= since_epoch else 0
    closed = st["wins"] + st["losses"]
    st["closed"] = closed
    st["win_rate"] = round(100.0 * st["wins"] / closed, 2) if closed else None
    st["profit_r"] = round(st["profit_r"], 2)
    st["history"] = hist
    st["open"] = t is not None and t["dir"] != 0 and not t["resolved"]
    return st


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def _merge(base, override):
    out = copy.deepcopy(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def normalize_config(raw):
    """Fill defaults, migrate older config formats, and validate values."""
    raw = dict(raw or {})
    legacy_notify = {k: raw.pop(k) for k in ("telegram_bot_token", "telegram_chat_id") if k in raw}
    if "notify_termux" in raw:
        legacy_notify["termux"] = raw.pop("notify_termux")
    legacy_tpsl = raw.pop("notify_tp_sl", None)
    legacy_strategy = {k: raw.pop(k) for k in ("supertrend_factor", "atr_period", "sl_atr_mult", "tp_rr") if k in raw}
    if "assets" not in raw:
        pairs = None
        if raw.get("watchlist"):
            pairs = [(w["symbol"], w.get("timeframes", [15])) for w in raw["watchlist"]]
        elif raw.get("symbols"):
            pairs = [(s, raw.get("timeframes_minutes", [5, 15])) for s in raw["symbols"]]
        if pairs is not None:
            alerts = dict(DEFAULT_ALERTS)
            if legacy_tpsl is False:
                alerts.update(tp1=False, tp2=False, tp3=False, sl=False)
            raw["assets"] = [{"symbol": s, "timeframes": tfs, "alerts": dict(alerts)} for s, tfs in pairs]
    for k in ("watchlist", "symbols", "timeframes_minutes", "deriv_ws_url"):
        raw.pop(k, None)
    raw["notify"] = _merge(legacy_notify, raw.get("notify", {}))
    if "telegram" not in raw["notify"]:  # older configs: on when both fields were filled in
        raw["notify"]["telegram"] = bool(raw["notify"].get("telegram_bot_token") and raw["notify"].get("telegram_chat_id"))
    raw["strategy"] = _merge(legacy_strategy, raw.get("strategy", {}))

    cfg = _merge(DEFAULT_CONFIG, {k: v for k, v in raw.items() if k != "assets"})
    if "assets" in raw:
        cfg["assets"] = raw["assets"]

    assets, seen, dropped = [], set(), []
    for a in cfg["assets"]:
        sym = str(a.get("symbol", "")).strip()
        if not re.fullmatch(r"[A-Za-z0-9_]{2,30}", sym) or sym in seen:
            dropped.append(sym)
            continue
        seen.add(sym)
        tfs = sorted({int(t) for t in a.get("timeframes", []) if int(t) in TIMEFRAMES})
        assets.append({
            "symbol": sym,
            "label": str(a.get("label") or KNOWN_SYMBOLS.get(sym, sym))[:40],
            "enabled": bool(a.get("enabled", True)),
            "timeframes": tfs,
            "confirm_tf": int(a.get("confirm_tf") or 0) if int(a.get("confirm_tf") or 0) in TIMEFRAMES else 0,
            "alerts": _merge(DEFAULT_ALERTS, {k: bool(v) for k, v in (a.get("alerts") or {}).items() if k in DEFAULT_ALERTS}),
        })
    cfg["assets"] = assets
    if dropped:
        print("Ignored invalid or duplicate symbols: %s" % ", ".join(dropped), flush=True)

    s = cfg["strategy"]
    s["supertrend_factor"] = min(max(float(s["supertrend_factor"]), 0.1), 20.0)
    s["atr_period"] = min(max(int(s["atr_period"]), 1), 100)
    s["sl_atr_mult"] = min(max(float(s["sl_atr_mult"]), 0.1), 20.0)
    s["tp_rr"] = [min(max(float(x), 0.1), 50.0) for x in list(s["tp_rr"])[:3]] or [1.0, 2.0, 3.0]
    s["adx_filter"] = bool(s.get("adx_filter"))
    s["adx_min"] = min(max(float(s.get("adx_min", 25.0)), 1.0), 100.0)
    s["adx_length"] = min(max(int(s.get("adx_length", 14)), 1), 100)
    s["adx_smoothing"] = min(max(int(s.get("adx_smoothing", 14)), 1), 100)
    while len(s["tp_rr"]) < 3:
        s["tp_rr"].append(s["tp_rr"][-1] + 1.0)
    n = cfg["notify"]
    if n["style"] not in ("detailed", "compact"):
        n["style"] = "detailed"
    for key in ("signal_sound", "tpsl_sound"):
        if n[key] not in ("system", "tts", "file", "none"):
            n[key] = "system"
    if n["priority"] not in ("max", "high", "default", "low"):
        n["priority"] = "max"
    if n["tts_lang"] not in ("th", "en"):
        n["tts_lang"] = "th"
    n["led_color"] = re.sub(r"[^0-9a-fA-F]", "", str(n["led_color"]))[:6] or "00ff00"
    n["vibrate"] = re.sub(r"[^0-9,]", "", str(n["vibrate"]))[:40]
    n["telegram"] = bool(n.get("telegram"))
    for k in ("telegram_bot_token", "telegram_chat_id", "sound_file"):
        n[k] = str(n.get(k) or "").strip()
    for k in DEFAULT_CONFIG["notify"]["fields"]:
        n["fields"][k] = bool(n["fields"].get(k))
    cfg["poll_seconds"] = min(max(int(cfg["poll_seconds"]), 5), 300)
    cfg.pop("stats_candles", None)
    cfg["stats_days"] = min(max(int(cfg.get("stats_days", 7)), 1), 60)
    cfg["dashboard_port"] = int(cfg["dashboard_port"])
    return cfg


def load_config():
    raw = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    return normalize_config(raw)


def save_config(cfg):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)


def watch_pairs(cfg):
    """Enabled (asset, minutes) pairs."""
    return [(a, tf) for a in cfg["assets"] if a["enabled"] for tf in a["timeframes"]]


class Shared:
    """Config + status shared between the bot loop and the dashboard."""

    def __init__(self, cfg):
        self.lock = threading.Lock()
        self.cfg = cfg
        self.changed = threading.Event()
        self.status = {}
        self.log = []
        self.started = time.time()
        try:
            with open(LOG_PATH, encoding="utf-8") as f:
                self.log = json.load(f)[:50]
        except Exception:
            pass

    def get_cfg(self):
        with self.lock:
            return copy.deepcopy(self.cfg)

    def set_cfg(self, cfg):
        with self.lock:
            self.cfg = cfg
        save_config(cfg)
        self.changed.set()

    def set_status(self, key, **kw):
        with self.lock:
            self.status.setdefault(key, {}).update(kw)

    def add_log(self, title, body):
        with self.lock:
            self.log.insert(0, {"time": time.time(), "title": title, "body": body})
            del self.log[50:]
            self._save_log()

    def clear_log(self):
        with self.lock:
            self.log = []
            self._save_log()

    def _save_log(self):
        try:
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                json.dump(self.log, f, ensure_ascii=False)
        except OSError:
            pass

    def prune(self, keys):
        """Forget status of charts that were removed or switched off."""
        with self.lock:
            for k in list(self.status):
                if k not in keys:
                    del self.status[k]


# ---------------------------------------------------------------------------
# Deriv API
# ---------------------------------------------------------------------------
class DerivSymbolError(RuntimeError):
    pass


class Deriv:
    def __init__(self, cfg):
        self.urls = ["%s?app_id=%s" % (u, cfg["deriv_app_id"]) for u in cfg["deriv_ws_urls"]]
        self.idx = 0
        self.ws = None

    def _conn(self):
        if self.ws is not None:
            return self.ws
        errors = []
        for k in range(len(self.urls)):
            url = self.urls[(self.idx + k) % len(self.urls)]
            try:
                self.ws = websocket.create_connection(url, timeout=30, origin="https://app.deriv.com")
                self.idx = (self.idx + k) % len(self.urls)
                return self.ws
            except Exception as exc:
                errors.append("%s -> %s" % (url.split("/websockets")[0], str(exc)[:60]))
        raise ConnectionError("all Deriv servers failed: " + "; ".join(errors))

    def call(self, payload):
        try:
            ws = self._conn()
            ws.send(json.dumps(payload))
            resp = json.loads(ws.recv())
        except Exception:
            self.close()
            raise
        if "error" in resp:
            raise DerivSymbolError(resp["error"].get("message", "Deriv API error"))
        return resp

    def close(self):
        try:
            if self.ws is not None:
                self.ws.close()
        except Exception:
            pass
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
# Message formatting
# ---------------------------------------------------------------------------
def fmt(price, digits=None):
    if digits is not None:
        return "%.*f" % (digits, price)
    return ("%.5f" % price).rstrip("0").rstrip(".")


def fmt_time(epoch, cfg):
    return time.strftime("%d/%m %H:%M", time.gmtime(epoch + cfg["timezone_offset_hours"] * 3600))


def side_words(side):
    return ("BUY", "ซื้อ") if side == "LONG" else ("SELL", "ขาย")


def signal_message(asset, tf, trade, cfg, late=False):
    n = cfg["notify"]
    f = n["fields"]
    buy_sell, thai = side_words(trade["side"])
    d = trade.get("digits")
    icon = ("🟢 " if trade["side"] == "LONG" else "🔴 ") if n["emoji"] else ""
    title = "%s%s (%s) %s [%dm]%s" % (icon, buy_sell, thai, asset["label"], tf, " (แจ้งช้า)" if late else "")
    parts = []
    if f.get("entry"):
        parts.append(("เข้า", fmt(trade["entry"], d)))
    if f.get("sl"):
        sl_text = fmt(trade["sl"], d)
        if f.get("risk"):
            sl_text += " (ระยะ %s)" % fmt(abs(trade["entry"] - trade["sl"]), d)
        parts.append(("SL", sl_text))
    for k, tp in enumerate(trade["tps"]):
        if f.get("tp%d" % (k + 1)):
            parts.append(("TP%d" % (k + 1), fmt(tp, d)))
    if f.get("time"):
        # Candle OPEN time, the same label TradingView shows under each candle.
        parts.append(("แท่ง", fmt_time(trade["epoch"], cfg)))
    if n["style"] == "compact":
        body = " | ".join("%s %s" % p for p in parts)
    else:
        body = "\n".join("%s: %s" % p for p in parts)
    return title, body


def event_message(asset, tf, trade, event, cfg, hit_epoch=None):
    emoji = cfg["notify"]["emoji"]
    buy_sell, _ = side_words(trade["side"])
    d = trade.get("digits")
    if event == "SL":
        title = "%sโดน SL %s [%dm]" % ("⛔ " if emoji else "", asset["label"], tf)
        body = "ออเดอร์ %s ปิดที่ SL %s (−1R)" % (buy_sell, fmt(trade["sl"], d))
    elif event == "SL_AFTER_TP":
        best = max(k + 1 for k, hit in enumerate(trade["tp_hit"]) if hit)
        title = "%sกลับมาโดน SL %s [%dm]" % ("⛔ " if emoji else "", asset["label"], tf)
        body = "ออเดอร์ %s ถึง TP%d แล้วราคากลับมาที่ SL %s\nถ้าเลื่อน SL ไปที่จุดเข้า %s แล้ว = เสมอตัว" % (
            buy_sell, best, fmt(trade["sl"], d), fmt(trade["entry"], d))
    else:
        k = int(event[2:]) - 1
        title = "%sถึง %s %s [%dm]" % ("✅ " if emoji else "", event, asset["label"], tf)
        body = "ออเดอร์ %s: %s %s" % (buy_sell, event, fmt(trade["tps"][k], d))
        if k == 0 and len(trade["tps"]) > 1:
            body += "\nแนะนำเลื่อน SL ไปที่จุดเข้า %s" % fmt(trade["entry"], d)
    # Candle open times, same labels as TradingView.
    if hit_epoch is not None:
        body += "\nแท่งที่ถึง: %s" % fmt_time(hit_epoch, cfg)
    body += "\nแท่งที่เข้า: %s" % fmt_time(trade["epoch"], cfg)
    return title, body


def previous_trade_note(prev, events, price):
    """What to do with the earlier trade when a new signal arrives."""
    if prev is None:
        return ""
    buy_sell = side_words(prev["side"])[0]
    d = prev.get("digits")
    if "SL" in events:
        return "⚠️ ออเดอร์ %s เดิมโดน SL แล้วที่ %s (−1R)" % (buy_sell, fmt(prev["sl"], d))
    if "SL_AFTER_TP" in events:
        return "⚠️ ออเดอร์ %s เดิมกลับมาโดน SL แล้วที่ %s" % (buy_sell, fmt(prev["sl"], d))
    if prev["closed"]:
        return ""  # finished earlier (TP3 or SL), already notified
    risk = abs(prev["entry"] - prev["sl"]) or 1e-9
    sign = 1 if prev["side"] == "LONG" else -1
    r = (price - prev["entry"]) * sign / risk
    prev["closed"] = True
    return "⚠️ ปิดออเดอร์ %s เดิม (เข้า %s) ตอนนี้ที่ %s (%+.1fR)" % (buy_sell, fmt(prev["entry"], d), fmt(price, d), r)


def speech_text(asset, tf, kind, cfg):
    th = cfg["notify"]["tts_lang"] == "th"
    if kind in ("LONG", "SHORT"):
        word = ("ซื้อ" if kind == "LONG" else "ขาย") if th else ("Buy" if kind == "LONG" else "Sell")
    elif kind in ("SL", "SL_AFTER_TP"):
        word = "โดนสต็อปลอส" if th else "Stop loss hit"
    else:
        word = ("ถึง " + kind) if th else (kind + " reached")
    return "%s %s %d %s" % (word, asset["label"], tf, "นาที" if th else "minute")


def sample_trade(cfg):
    st = cfg["strategy"]
    entry, risk = 75000.0, 120.0
    return {"side": "LONG", "epoch": int(time.time()) // 60 * 60 - 60, "entry": entry, "sl": entry - risk,
            "tps": [entry + risk * rr for rr in st["tp_rr"]], "tp_hit": [False] * 3, "closed": False, "digits": 2}


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
def _spawn(args):
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def notify(cfg, title, body, sound_mode="system", speech="", group="signals", shared=None):
    n = cfg["notify"]
    print("\n=== %s ===\n%s\n" % (title, body), flush=True)
    if shared is not None:
        shared.add_log(title, body)
    if n.get("telegram") and n.get("telegram_bot_token") and n.get("telegram_chat_id"):
        try:
            data = urllib.parse.urlencode({"chat_id": n["telegram_chat_id"], "text": title + "\n" + body}).encode()
            url = "https://api.telegram.org/bot%s/sendMessage" % n["telegram_bot_token"]
            urllib.request.urlopen(url, data=data, timeout=20).read()
        except Exception as exc:
            print("Telegram send failed: %s" % exc, flush=True)
    if n.get("termux"):
        args = ["termux-notification", "--title", title, "--content", body,
                "--priority", n["priority"], "--group", group,
                "--led-color", n["led_color"], "--id", "st%d" % (int(time.time() * 1000) % 10000000)]
        if n.get("vibrate"):
            args += ["--vibrate", n["vibrate"]]
        if sound_mode == "system":
            args.append("--sound")
        try:
            subprocess.run(args, check=False, timeout=20)
        except FileNotFoundError:
            pass  # Termux:API not installed
        except Exception as exc:
            print("Termux notification failed: %s" % exc, flush=True)
        if sound_mode == "tts" and speech:
            _spawn(["termux-tts-speak", "-l", n["tts_lang"], speech])
        elif sound_mode == "file" and n.get("sound_file"):
            _spawn(["termux-media-player", "play", os.path.expanduser(n["sound_file"])])


# ---------------------------------------------------------------------------
# Bot loop
# ---------------------------------------------------------------------------
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


def htf_direction_at(deriv, cfg, symbol, htf, open_epoch, cache):
    """Supertrend direction of the last higher-timeframe candle that CLOSED by `open_epoch`
    (same as the indicator's request.security(..., direction[1], lookahead_on))."""
    key = (symbol, htf)
    if key not in cache:
        c = deriv.closed_candles(symbol, htf * 60, cfg["candles"])
        s = cfg["strategy"]
        _, d, _ = supertrend([x["high"] for x in c], [x["low"] for x in c], [x["close"] for x in c],
                             s["supertrend_factor"], s["atr_period"])
        cache[key] = (c, d)
    c, d = cache[key]
    for j in range(len(c) - 1, -1, -1):
        if c[j]["epoch"] + htf * 60 <= open_epoch:
            return d[j]
    return None


def filter_reasons(deriv, cfg, asset, tf, side, i, candle, adx, cache):
    """Why a signal is blocked by the optional filters (empty list = allowed)."""
    s = cfg["strategy"]
    reasons = []
    if s["adx_filter"] and (adx[i] is None or adx[i] <= s["adx_min"]):
        reasons.append("ADX %s ≤ %g" % ("-" if adx[i] is None else "%.1f" % adx[i], s["adx_min"]))
    htf = asset.get("confirm_tf") or 0
    if htf > tf:
        d = htf_direction_at(deriv, cfg, asset["symbol"], htf, candle["epoch"], cache)
        need = -1 if side == "LONG" else 1
        if d != need:
            reasons.append("เทรนด์ %dm เป็น%s" % (htf, "ขาขึ้น" if d == -1 else "ขาลง" if d == 1 else "ไม่ทราบ"))
    return reasons


STATS_CACHE = {}  # key -> {"candles": [...], "sig": settings signature, "last": epoch}


def update_stats(deriv, cfg, asset, tf, candles, shared, cache):
    """Keep a longer candle history per chart (fetched once, then extended with the
    regular 300-candle fetch) and recompute the win-rate table when it changes."""
    key = "%s_%d" % (asset["symbol"], tf)
    days = cfg["stats_days"]
    # enough candles for the window plus warm-up for ATR / ADX / Supertrend
    want = min(5000, days * 1440 // tf + 200)
    s = cfg["strategy"]
    sig = json.dumps([s, asset.get("confirm_tf"), days], sort_keys=True)
    entry = STATS_CACHE.get(key)
    if entry is None or entry["want"] != want:
        entry = {"candles": deriv.closed_candles(asset["symbol"], tf * 60, want), "sig": None, "last": 0, "want": want}
        STATS_CACHE[key] = entry
    merged = {c["epoch"]: c for c in entry["candles"]}
    merged.update({c["epoch"]: c for c in candles})
    entry["candles"] = [merged[e] for e in sorted(merged)][-want:]
    c = entry["candles"]
    if entry["sig"] == sig and entry["last"] == c[-1]["epoch"]:
        return
    H, L, C = [x["high"] for x in c], [x["low"] for x in c], [x["close"] for x in c]
    _, direction, atr = supertrend(H, L, C, s["supertrend_factor"], s["atr_period"])
    _, _, adx = adx_dmi(H, L, C, s["adx_length"], s["adx_smoothing"])
    allowed = lambda i, side: not filter_reasons(deriv, cfg, asset, tf, side, i, c[i], adx, cache)
    since = max(c[-1]["epoch"] + tf * 60 - days * 86400, c[min(len(c) - 1, 100)]["epoch"])
    res = backtest(c, direction, atr, s, allowed, since_epoch=since)
    for h in res["history"]:
        h["time"] = fmt_time(h.pop("epoch"), cfg)
    res.update(days=round((c[-1]["epoch"] + tf * 60 - since) / 86400.0, 1),
               since=fmt_time(since, cfg), until=fmt_time(c[-1]["epoch"], cfg))
    entry["sig"], entry["last"] = sig, c[-1]["epoch"]
    shared.set_status(key, stats=res)


def publish_trade(shared, key, st, cfg):
    """Show the tracked trade (entry / SL / TPs, which TPs were hit) on the dashboard."""
    t = st.get("trade")
    if shared is None or not t:
        return
    dg = t.get("digits")
    shared.set_status(key, trade={
        "side": t["side"], "entry": fmt(t["entry"], dg), "sl": fmt(t["sl"], dg),
        "tps": [fmt(x, dg) for x in t["tps"]], "tp_hit": t["tp_hit"], "closed": t["closed"],
        "time": fmt_time(t["epoch"], cfg)})


def process(deriv, cfg, state, asset, tf, shared=None, cache=None):
    cache = {} if cache is None else cache
    symbol = asset["symbol"]
    key = "%s_%d" % (symbol, tf)
    gran = tf * 60
    strategy = cfg["strategy"]
    alerts = asset["alerts"]
    n = cfg["notify"]
    candles = deriv.closed_candles(symbol, gran, cfg["candles"])
    if len(candles) < strategy["atr_period"] + 2:
        return
    highs = [c["high"] for c in candles]
    lows = [c["low"] for c in candles]
    closes = [c["close"] for c in candles]
    _, direction, atr = supertrend(highs, lows, closes, strategy["supertrend_factor"], strategy["atr_period"])
    _, _, adx = adx_dmi(highs, lows, closes, strategy["adx_length"], strategy["adx_smoothing"])
    digits = price_digits(candles)
    if shared is not None:
        shared.set_status(key, symbol=symbol, label=asset["label"], tf=tf, checked=time.time(),
                          candle=fmt_time(candles[-1]["epoch"], cfg), close=fmt(closes[-1]),
                          trend="UP" if direction[-1] == -1 else "DOWN", error="",
                          adx="-" if adx[-1] is None else "%.1f" % adx[-1])
    if shared is not None:
        try:
            update_stats(deriv, cfg, asset, tf, candles, shared, cache)
        except DerivSymbolError:
            raise
        except Exception as exc:  # statistics are informational; never stop the alerts
            print("%s %s: stats error %s" % (time.strftime("%H:%M:%S"), key, exc), flush=True)
    st = state.setdefault(key, {"last_epoch": 0, "trade": None})
    if candles[-1]["epoch"] <= st["last_epoch"]:
        publish_trade(shared, key, st, cfg)  # e.g. right after a restart
        return  # no new closed candle yet
    first_run = st["last_epoch"] == 0

    # Walk every candle that closed since the last check (the phone may have slept).
    for i, candle in enumerate(candles):
        if candle["epoch"] <= st["last_epoch"]:
            continue
        side = signal_at(direction, i)
        prev = st["trade"]
        # Check the open trade FIRST, also on a candle that flips the signal,
        # so an SL/TP hit on the reversal candle is never skipped.
        # On the first run this replays history silently, so old trades show their real state.
        events = update_trade(prev, candle)
        if not first_run:
            for ev in events:
                # TP/SL alerts follow the BUY/SELL switch: without the entry alert they make no sense.
                if alerts["signal"] and alerts.get("sl" if ev.startswith("SL") else ev.lower()):
                    title, body = event_message(asset, tf, prev, ev, cfg, candle["epoch"])
                    notify(cfg, title, body, n["tpsl_sound"], speech_text(asset, tf, ev, cfg), symbol, shared)
        if side:
            reasons = filter_reasons(deriv, cfg, asset, tf, side, i, candle, adx, cache)
            if reasons:
                msg = "%s %s ถูกกรอง (%s)" % (side_words(side)[0], fmt_time(candle["epoch"], cfg), ", ".join(reasons))
                if not first_run:  # don't list every old filtered signal at startup
                    print("%s %s: %s" % (time.strftime("%H:%M:%S"), key, msg), flush=True)
                if shared is not None:
                    shared.set_status(key, filtered=msg)
                continue
            st["trade"] = make_trade(side, candle, atr[i], strategy, digits)
            if shared is not None:
                shared.set_status(key, filtered="")
            if not first_run and alerts["signal"]:
                title, body = signal_message(asset, tf, st["trade"], cfg, late=i < len(candles) - 1)
                note = previous_trade_note(prev, events, candle["close"])
                if note:
                    body += "\n" + note
                notify(cfg, title, body, n["signal_sound"], speech_text(asset, tf, side, cfg), symbol, shared)
    st["last_epoch"] = candles[-1]["epoch"]
    publish_trade(shared, key, st, cfg)


def run_loop(shared):
    state = load_state()
    cfg = shared.get_cfg()
    deriv = Deriv(cfg)
    backoff = 5
    while True:
        cfg = shared.get_cfg()
        keys = {"%s_%d" % (a["symbol"], tf) for a, tf in watch_pairs(cfg)}
        shared.prune(keys)
        for k in list(STATS_CACHE):
            if k not in keys:
                del STATS_CACHE[k]
        cache = {}  # higher-timeframe candles, fetched at most once per round
        try:
            for asset, tf in watch_pairs(cfg):
                key = "%s_%d" % (asset["symbol"], tf)
                try:
                    process(deriv, cfg, state, asset, tf, shared, cache)
                except DerivSymbolError as exc:  # bad symbol etc.: report it, keep the others running
                    shared.set_status(key, symbol=asset["symbol"], label=asset["label"], tf=tf,
                                      checked=time.time(), error=str(exc))
                    print("%s %s: %s" % (time.strftime("%H:%M:%S"), key, exc), flush=True)
            save_state(state)
            print("%s checked %d chart(s)" % (time.strftime("%H:%M:%S"), len(watch_pairs(cfg))), flush=True)
            backoff = 5
            shared.changed.wait(cfg["poll_seconds"])
            shared.changed.clear()
        except Exception as exc:
            print("%s error: %s (retry in %ds)" % (time.strftime("%H:%M:%S"), exc, backoff), flush=True)
            deriv.close()
            time.sleep(backoff)
            backoff = min(backoff * 2, 300)


# ---------------------------------------------------------------------------
# Dashboard (http://127.0.0.1:<port>, only reachable from this phone)
# ---------------------------------------------------------------------------
def make_handler(shared):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, code, body, ctype="application/json; charset=utf-8"):
            data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length) or b"{}")

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/":
                self._send(200, DASHBOARD_HTML.encode("utf-8"), "text/html; charset=utf-8")
            elif path == "/api/config":
                self._send(200, {"config": shared.get_cfg(), "symbols": KNOWN_SYMBOLS, "timeframes": TIMEFRAMES})
            elif path == "/api/status":
                with shared.lock:
                    self._send(200, {"status": shared.status, "log": shared.log, "started": shared.started,
                                     "now": time.time()})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            path = self.path.split("?")[0]
            if path == "/api/log/clear":
                shared.clear_log()
                self._send(200, {"ok": True})
                return
            try:
                cfg = normalize_config(self._body())
            except Exception as exc:
                self._send(400, {"error": "invalid settings: %s" % exc})
                return
            enabled = [a for a in cfg["assets"] if a["enabled"]] or cfg["assets"]
            asset = enabled[0] if enabled else {"symbol": "cryBTCUSD", "label": "BTCUSD", "timeframes": [1]}
            tf = (asset.get("timeframes") or [1])[0]
            trade = sample_trade(cfg)
            sig = signal_message(asset, tf, trade, cfg)
            tp = event_message(asset, tf, trade, "TP1", cfg, trade["epoch"] + tf * 60)
            sl = event_message(asset, tf, trade, "SL", cfg, trade["epoch"] + 2 * tf * 60)
            if path == "/api/config":
                shared.set_cfg(cfg)
                self._send(200, {"ok": True, "config": cfg})
            elif path == "/api/preview":
                self._send(200, {"signal": sig, "tp": tp, "sl": sl})
            elif path == "/api/test":
                n = cfg["notify"]
                notify(cfg, "🧪 ทดสอบ " + sig[0], sig[1], n["signal_sound"],
                       speech_text(asset, tf, "LONG", cfg), "test", shared)
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})

    return Handler


def start_dashboard(shared):
    port = shared.get_cfg()["dashboard_port"]
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(shared))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return "http://127.0.0.1:%d" % port


DASHBOARD_HTML = r"""<!doctype html>
<html lang="th"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Signal Bot</title>
<style>
:root{--bg:#0e1014;--card:#171a21;--card2:#1e222b;--line:#2a2f3a;--fg:#e8eaed;--mut:#98a0ab;--acc:#3b82f6;--acc2:#1d4ed8;--up:#22c55e;--dn:#ef4444;--warn:#f59e0b;--r:14px}
@media (prefers-color-scheme: light){:root{--bg:#f3f4f6;--card:#fff;--card2:#f6f7f9;--line:#e1e4e8;--fg:#14171a;--mut:#5f6670;--up:#15803d;--dn:#dc2626;--warn:#b45309}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{background:var(--bg)}
body{margin:0;color:var(--fg);font:15px/1.45 system-ui,-apple-system,"Noto Sans Thai",sans-serif;padding-bottom:110px}
.wrap{max-width:640px;margin:0 auto;padding:0 14px}
header{padding:14px 0 6px;display:flex;align-items:center;justify-content:space-between;gap:10px}
header h1{font-size:19px;margin:0}
.live{font-size:12.5px;color:var(--mut);display:flex;align-items:center;gap:6px}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mut)}.dot.ok{background:var(--up);box-shadow:0 0 0 3px color-mix(in srgb,var(--up) 25%,transparent)}.dot.bad{background:var(--dn)}
nav{position:sticky;top:0;z-index:5;background:var(--bg);display:grid;grid-template-columns:repeat(5,1fr);gap:4px;padding:8px 0}
nav::-webkit-scrollbar{display:none}
nav button{border:1px solid var(--line);background:var(--card);color:var(--mut);border-radius:12px;padding:6px 2px;font:inherit;font-size:12px;white-space:nowrap;display:flex;flex-direction:column;align-items:center;gap:1px}nav button span{font-size:18px;line-height:1.2}
nav button.on{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
section{display:none}section.on{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:14px;margin:10px 0}
.card h2{font-size:15.5px;margin:0 0 4px}.hint{color:var(--mut);font-size:13px;margin:0 0 10px}
.mut{color:var(--mut)}.small{font-size:12.5px}
.row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.between{justify-content:space-between}.grow{flex:1;min-width:0}
.field{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 0;border-top:1px solid var(--line)}
.field:first-of-type{border-top:0}.field>span:first-child{flex:1}.field .sub{display:block;color:var(--mut);font-size:12.5px}
input[type=text],input[type=number],input[type=password],select{background:var(--card2);color:var(--fg);border:1px solid var(--line);border-radius:10px;padding:9px 10px;font:inherit;min-width:0}
input:focus,select:focus{outline:2px solid var(--acc);outline-offset:0}
input[type=number]{width:86px;text-align:right}input:disabled,select:disabled{opacity:.45}
input[type=color]{width:44px;height:36px;border:1px solid var(--line);border-radius:10px;background:var(--card2);padding:2px}
button{font:inherit;cursor:pointer;transition:transform .08s,opacity .15s,background .15s}
button:active{transform:scale(.96)}button:disabled{opacity:.5;cursor:default;transform:none}
.btn{border:0;border-radius:12px;padding:11px 16px;font-weight:600;background:var(--acc);color:#fff}
.btn.sec{background:var(--card2);color:var(--fg);border:1px solid var(--line)}
.btn.danger{background:transparent;color:var(--dn);border:1px solid var(--dn)}
.btn.sm{padding:7px 12px;font-size:14px;border-radius:10px}
/* switch */
.sw{position:relative;width:46px;height:28px;flex:0 0 auto}.sw input{opacity:0;width:0;height:0;position:absolute}
.sw i{position:absolute;inset:0;background:var(--line);border-radius:999px;transition:.2s}
.sw i:after{content:"";position:absolute;width:22px;height:22px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s;box-shadow:0 1px 3px #0005}
.sw input:checked+i{background:var(--acc)}.sw input:checked+i:after{transform:translateX(18px)}
.sw input:disabled+i{opacity:.4}
/* chips / toggles */
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{border:1px solid var(--line);background:var(--card2);color:var(--fg);border-radius:999px;padding:6px 12px;font-size:14px}
.chip.on{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
.chip.on:before{content:"✓ "}
.chip:disabled{opacity:.35}
.seg{display:flex;background:var(--card2);border:1px solid var(--line);border-radius:12px;padding:3px;gap:3px}
.seg button{flex:1;border:0;background:transparent;color:var(--mut);border-radius:9px;padding:8px 6px;font-size:14px}
.seg button.on{background:var(--acc);color:#fff;font-weight:600}
/* overview */
.chart{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:12px 14px;margin:10px 0}
.chart .top{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.chart .name{font-weight:700;font-size:16px}.tf{color:var(--mut);font-weight:600;margin-left:4px}
.pill{display:inline-block;border-radius:999px;padding:2px 10px;font-weight:700;font-size:13px}
.pill.UP{background:color-mix(in srgb,var(--up) 18%,transparent);color:var(--up)}
.pill.DOWN{background:color-mix(in srgb,var(--dn) 18%,transparent);color:var(--dn)}
.kv{display:flex;gap:14px;flex-wrap:wrap;margin-top:6px;font-size:13.5px}.kv b{font-weight:600}
.trade{margin-top:10px;background:var(--card2);border:1px solid var(--line);border-radius:12px;padding:10px}
.trade .lv{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:6px}
.lv div{font-size:13px}.lv b{display:block;font-size:14.5px;font-variant-numeric:tabular-nums}
.lv .hit b{color:var(--up)}.lv .hit b:after{content:" ✓"}
.side{font-weight:800}.side.LONG{color:var(--up)}.side.SHORT{color:var(--dn)}
.note{margin-top:8px;font-size:13px;padding:7px 10px;border-radius:10px;background:var(--card2);border:1px solid var(--line)}
.note.warn{border-color:color-mix(in srgb,var(--warn) 50%,transparent);color:var(--warn)}
.note.err{border-color:color-mix(in srgb,var(--dn) 50%,transparent);color:var(--dn)}
.log{border-top:1px solid var(--line);padding:10px 0;white-space:pre-wrap;font-size:13.5px}.log:first-child{border-top:0}
.log b{display:block;font-size:14.5px}.log .t{color:var(--mut);font-size:12px}
/* stats */
.sgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:8px}
.sgrid div{background:var(--card2);border:1px solid var(--line);border-radius:10px;padding:7px 4px;text-align:center;font-size:12.5px;color:var(--mut)}
.sgrid b{display:block;font-size:17px;color:var(--fg);font-variant-numeric:tabular-nums}
.pos{color:var(--up)!important}.neg{color:var(--dn)!important}
table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px}td,th{text-align:left;padding:6px 4px;border-bottom:1px solid var(--line)}th{color:var(--mut);font-weight:600}
details>summary{cursor:pointer;list-style:none;color:var(--acc);font-size:14px;margin-top:8px}details>summary::-webkit-details-marker{display:none}
details>summary:before{content:"▸ "}details[open]>summary:before{content:"▾ "}
/* assets */
.asset{background:var(--card);border:1px solid var(--line);border-radius:var(--r);margin:10px 0;overflow:hidden}
.asset.off{opacity:.6}
.ahead{display:flex;align-items:center;gap:12px;padding:12px 14px}
.ahead .info{flex:1;min-width:0;cursor:pointer}.ahead .sum{color:var(--mut);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ahead .chev{color:var(--mut);font-size:18px;cursor:pointer;padding:4px;transition:transform .2s}.asset.open .chev{transform:rotate(90deg)}
.abody{display:none;padding:0 14px 14px;border-top:1px solid var(--line)}.asset.open .abody{display:block}
.lbl{font-size:13px;color:var(--mut);margin:12px 0 6px;font-weight:600}
/* save bar + toast */
.bar{position:fixed;left:0;right:0;bottom:0;z-index:10;background:var(--card);border-top:1px solid var(--line);padding:10px 14px calc(10px + env(safe-area-inset-bottom));transform:translateY(110%);transition:transform .25s}
.bar{visibility:hidden}.bar.show{transform:none;visibility:visible}.bar .wrap{display:flex;gap:8px;align-items:center;padding:0}
.bar .msg{flex:1;font-size:13.5px;color:var(--warn);font-weight:600}
.toast{position:fixed;left:50%;top:14px;transform:translate(-50%,-150%);z-index:20;background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:12px;font-weight:600;font-size:14px;transition:transform .25s;max-width:90vw;text-align:center}
.toast.show{transform:translate(-50%,0)}.toast.err{background:var(--dn);color:#fff}
.prev{background:var(--card2);border:1px solid var(--line);border-radius:12px;padding:10px;white-space:pre-wrap;font-size:13.5px;margin-top:8px}
.prev b{display:block}
.empty{color:var(--mut);text-align:center;padding:22px 8px}
</style></head><body>
<div class="wrap">
<header><h1>📡 Signal Bot</h1><div class="live"><span class="dot" id="dot"></span><span id="live">กำลังเชื่อมต่อ…</span></div></header>
<nav id="tabs">
<button data-tab="ov"><span>📊</span>ภาพรวม</button><button data-tab="st"><span>🏆</span>สถิติ</button><button data-tab="as"><span>📈</span>สินทรัพย์</button><button data-tab="nt"><span>🔔</span>แจ้งเตือน</button><button data-tab="ad"><span>⚙️</span>ขั้นสูง</button>
</nav>

<section id="ov">
<div id="charts"></div>
<div class="card"><div class="row between"><h2>🕑 แจ้งเตือนล่าสุด</h2><button class="btn sec sm" id="clearLog">ล้าง</button></div>
<div id="log"></div></div>
</section>

<section id="st">
<div class="card"><div class="field"><span>นับสถิติย้อนหลัง<span class="sub">นับเฉพาะเทรดที่เข้าภายในช่วงนี้ · ตั้งให้ตรงกับ "นับสถิติย้อนหลัง (วัน)" ในอินดิเคเตอร์</span></span>
<span class="row"><input type="number" min="1" max="60" data-k="stats_days"> วัน</span></div>
<p class="hint" style="margin:6px 0 0">ถึง TP1 ก่อน = ชนะ (+TP1 R) · โดน SL ก่อน = แพ้ (−1R) · กลับทิศก่อนรู้ผล = คิดตามกำไร/ขาดทุนจริง · เทรดที่ยังเปิดไม่นับ · ใช้ค่าและตัวกรองปัจจุบัน</p></div>
<div id="stats"></div>
</section>

<section id="as">
<div id="assets"></div>
<div class="card"><h2>➕ เพิ่มสินทรัพย์</h2>
<div class="row"><select id="addSel" class="grow"></select><button class="btn sm" id="addBtn">เพิ่ม</button></div>
<div class="row" id="addCodeRow" style="margin-top:8px;display:none"><input type="text" id="addCode" class="grow" placeholder="รหัส Deriv เช่น R_50" autocapitalize="off" autocomplete="off" spellcheck="false"></div>
<p class="hint" style="margin:8px 0 0">รหัสต้องตรงกับ Deriv ทุกตัวอักษร ถ้าผิด หน้าภาพรวมจะขึ้นข้อความแจ้ง</p></div>
<div class="card"><h2>🧹 ตัวกรองสัญญาณ (ใช้กับทุกสินทรัพย์)</h2>
<p class="hint">ลดสัญญาณหลอกตอนตลาดไซด์เวย์ · ควรตั้งให้ตรงกับอินดิเคเตอร์</p>
<div class="field"><span>แจ้งเฉพาะตอน ADX แรงพอ<span class="sub">ADX = ความแรงเทรนด์ · ต่ำกว่า 20 ไซด์เวย์ · 25+ มีเทรนด์</span></span><label class="sw"><input type="checkbox" data-k="strategy.adx_filter"><i></i></label></div>
<div class="field" data-dep="strategy.adx_filter"><span>ADX ขั้นต่ำ</span><input type="number" step="0.5" data-k="strategy.adx_min"></div>
<p class="hint" style="margin:6px 0 0">ยืนยันด้วยเทรนด์ TF ใหญ่ ตั้งแยกในแต่ละสินทรัพย์ด้านบน</p></div>
</section>

<section id="nt">
<div class="card"><h2>📬 ช่องทาง</h2>
<div class="field"><span>เด้งแจ้งเตือนในมือถือ<span class="sub">ผ่าน Termux:API · ใช้เสียง การสั่น และไฟ LED ด้านล่าง</span></span><label class="sw"><input type="checkbox" data-k="notify.termux"><i></i></label></div>
<div class="field"><span>Telegram<span class="sub">ส่งเข้าแชต Telegram ด้วย</span></span><label class="sw"><input type="checkbox" data-k="notify.telegram"><i></i></label></div>
<div data-dep="notify.telegram" data-hide="1">
<div class="field"><span>Bot token</span><input type="password" class="grow" data-k="notify.telegram_bot_token" placeholder="123456:ABC…" autocomplete="off"></div>
<div class="field"><span>chat_id</span><input type="text" class="grow" data-k="notify.telegram_chat_id" placeholder="123456789" autocomplete="off"></div></div>
<div id="chanWarn"></div></div>

<div class="card" data-dep="notify.termux" data-hide="1"><h2>🔊 เสียง &amp; การสั่น (ในมือถือ)</h2>
<div class="field"><span>เสียง BUY / SELL</span><select data-k="notify.signal_sound" data-opts="sound"></select></div>
<div class="field"><span>เสียง TP / SL</span><select data-k="notify.tpsl_sound" data-opts="sound"></select></div>
<div class="field" id="ttsRow"><span>ภาษาเสียงพูด</span><select data-k="notify.tts_lang"><option value="th">ไทย</option><option value="en">English</option></select></div>
<div class="field" id="fileRow"><span>ไฟล์เสียง<span class="sub">เช่น ~/storage/downloads/alert.mp3</span></span><input type="text" class="grow" data-k="notify.sound_file" placeholder="~/storage/downloads/alert.mp3"></div>
<div class="field"><span>การสั่น</span><select data-k="notify.vibrate" data-opts="vib"></select></div>
<div class="field"><span>ความสำคัญ<span class="sub">สูงสุด = เด้งบนจอแม้ใช้แอปอื่นอยู่</span></span><select data-k="notify.priority"><option value="max">สูงสุด</option><option value="high">สูง</option><option value="default">ปกติ</option><option value="low">ต่ำ (เงียบ)</option></select></div>
<div class="field"><span>สีไฟ LED<span class="sub">เฉพาะเครื่องที่มีไฟแจ้งเตือน</span></span><input type="color" data-k="notify.led_color"></div></div>

<div class="card"><h2>💬 หน้าตาข้อความ</h2>
<div class="lbl" style="margin-top:4px">รูปแบบ</div>
<div class="seg" data-seg="notify.style"><button data-v="detailed">ละเอียด (หลายบรรทัด)</button><button data-v="compact">ย่อ (บรรทัดเดียว)</button></div>
<div class="lbl">ข้อมูลในแจ้งเตือน BUY / SELL</div>
<div class="chips" id="fields"></div>
<div class="field" style="margin-top:6px"><span>ใส่อีโมจิ 🟢🔴✅⛔</span><label class="sw"><input type="checkbox" data-k="notify.emoji"><i></i></label></div>
<div class="lbl">ตัวอย่าง</div><div id="preview" class="mut small">-</div>
<button class="btn sec" id="testBtn" style="width:100%;margin-top:10px">🧪 ส่งแจ้งเตือนทดสอบ</button>
<p class="hint" style="margin:6px 0 0">ใช้ค่าบนหน้านี้ทันที ไม่ต้องบันทึกก่อน</p></div>
</section>

<section id="ad">
<div class="card"><h2>🧮 ค่าการคำนวณ</h2><p class="hint">ต้องตรงกับ Settings ของอินดิเคเตอร์ ไม่งั้นสัญญาณจะไม่ตรงกัน</p>
<div class="field"><span>Supertrend factor</span><input type="number" step="0.1" data-k="strategy.supertrend_factor"></div>
<div class="field"><span>ATR length</span><input type="number" data-k="strategy.atr_period"></div>
<div class="field"><span>SL = ATR ×</span><input type="number" step="0.1" data-k="strategy.sl_atr_mult"></div>
<div class="field"><span>TP1 (R)</span><input type="number" step="0.1" data-k="strategy.tp_rr.0"></div>
<div class="field"><span>TP2 (R)</span><input type="number" step="0.1" data-k="strategy.tp_rr.1"></div>
<div class="field"><span>TP3 (R)</span><input type="number" step="0.1" data-k="strategy.tp_rr.2"></div></div>
<div class="card"><h2>⏱️ การทำงาน</h2>
<div class="field"><span>เช็กราคาทุก<span class="sub">5–300 วินาที · ยิ่งถี่ยิ่งเปลืองแบต/เน็ต</span></span><span class="row"><input type="number" data-k="poll_seconds"> วิ</span></div></div>
</section>
</div>

<div class="bar" id="bar"><div class="wrap"><span class="msg">● มีการแก้ไขที่ยังไม่บันทึก</span>
<button class="btn sec sm" id="undoBtn">ยกเลิก</button><button class="btn sm" id="saveBtn">💾 บันทึก</button></div></div>
<div class="toast" id="toast"></div>

<script>
const $=id=>document.getElementById(id);
let cfg=null,saved="",SYMS={},TFS=[],openAsset=null,status={};
const FIELDS={entry:"จุดเข้า",sl:"SL",risk:"ระยะ SL",tp1:"TP1",tp2:"TP2",tp3:"TP3",time:"เวลาแท่ง"};
const ALERTS={signal:"BUY/SELL",tp1:"TP1",tp2:"TP2",tp3:"TP3",sl:"SL"};
const OPTS={sound:{system:"เสียงแจ้งเตือนของเครื่อง",tts:"พูดออกเสียง",file:"ไฟล์เสียงของฉัน",none:"ไม่มีเสียง"},
 vib:{"":"ไม่สั่น","300":"สั้น","500,200,500":"2 ครั้ง","800,200,800,200,800":"3 ครั้งยาว"}};
const tfName=m=>m<60?m+"m":m<1440?(m/60)+"h":"1D";
const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const ago=s=>s<60?Math.round(s)+" วิ":s<3600?Math.round(s/60)+" นาที":Math.round(s/3600)+" ชม.";
function toast(t,err){const e=$("toast");e.textContent=t;e.className="toast show"+(err?" err":"");clearTimeout(e._t);e._t=setTimeout(()=>e.className="toast",2600)}
function getK(k){return k.split(".").reduce((o,p)=>o?.[p],cfg)}
function setK(k,v){const ps=k.split(".");const last=ps.pop();ps.reduce((o,p)=>o[p],cfg)[last]=v}
const dirty=()=>JSON.stringify(cfg)!==saved;

/* ---------- tabs ---------- */
function tab(id){document.querySelectorAll("nav button").forEach(b=>b.classList.toggle("on",b.dataset.tab===id));
 document.querySelectorAll("section").forEach(s=>s.classList.toggle("on",s.id===id));try{localStorage.setItem("tab",id)}catch(e){}}
$("tabs").onclick=e=>{const b=e.target.closest("button");if(b){tab(b.dataset.tab);scrollTo(0,0)}};

/* ---------- generic bound inputs (data-k) ---------- */
function fillBound(){
 document.querySelectorAll("select[data-opts]").forEach(s=>{const o={...OPTS[s.dataset.opts]};const v=getK(s.dataset.k);if(!(v in o))o[v]=v;
  s.innerHTML=Object.entries(o).map(([k,t])=>`<option value="${esc(k)}">${esc(t)}</option>`).join("")});
 document.querySelectorAll("[data-k]").forEach(e=>{const v=getK(e.dataset.k);
  if(e.type==="checkbox")e.checked=!!v;else if(e.type==="color")e.value="#"+v;else e.value=v??""});
 document.querySelectorAll("[data-seg]").forEach(s=>s.querySelectorAll("button").forEach(b=>b.classList.toggle("on",getK(s.dataset.seg)===b.dataset.v)));
 renderFields();
}
document.addEventListener("input",e=>{const el=e.target;if(!el.dataset.k)return;
 let v=el.type==="checkbox"?el.checked:el.type==="color"?el.value.replace("#",""):el.type==="number"?(el.value===""?getK(el.dataset.k):+el.value):el.value;
 setK(el.dataset.k,v);changed()});
document.addEventListener("click",e=>{const b=e.target.closest("[data-seg] button");if(!b)return;
 setK(b.closest("[data-seg]").dataset.seg,b.dataset.v);fillBound();changed()});

/* things that depend on other settings */
function deps(){
 document.querySelectorAll("[data-dep]").forEach(el=>{const on=!!getK(el.dataset.dep);
  if(el.dataset.hide)el.style.display=on?"":"none";else el.querySelectorAll("input,select").forEach(i=>i.disabled=!on)});
 const n=cfg.notify,snd=[n.signal_sound,n.tpsl_sound];
 $("ttsRow").style.display=snd.includes("tts")?"":"none";$("fileRow").style.display=snd.includes("file")?"":"none";
 let w="";
 if(!n.termux&&!n.telegram)w='<div class="note err">ปิดทั้งสองช่องทาง = จะไม่ได้รับแจ้งเตือนเลย</div>';
 else if(n.telegram&&(!n.telegram_bot_token||!n.telegram_chat_id))w='<div class="note warn">ใส่ Bot token และ chat_id ให้ครบ ไม่งั้น Telegram จะไม่ส่ง</div>';
 if(snd.includes("file")&&!n.sound_file)w+='<div class="note warn">เลือก "ไฟล์เสียงของฉัน" แต่ยังไม่ได้ใส่ที่อยู่ไฟล์</div>';
 $("chanWarn").innerHTML=w;
}
function renderFields(){const f=cfg.notify.fields;
 $("fields").innerHTML=Object.entries(FIELDS).map(([k,t])=>`<button class="chip ${f[k]?"on":""}" data-field="${k}" ${k==="risk"&&!f.sl?"disabled":""}>${t}</button>`).join("")}
$("fields").onclick=e=>{const b=e.target.closest("[data-field]");if(!b)return;const f=cfg.notify.fields;f[b.dataset.field]=!f[b.dataset.field];renderFields();changed()};

function changed(){deps();$("bar").classList.toggle("show",dirty());preview()}

/* ---------- assets ---------- */
function assetSummary(a){
 if(!a.enabled)return"ปิดอยู่ · ไม่เช็กและไม่แจ้งเตือน";
 if(!a.timeframes.length)return"⚠️ ยังไม่ได้เลือกไทม์เฟรม";
 const al=Object.entries(ALERTS).filter(([k])=>a.alerts[k]).map(([,v])=>v);
 return a.timeframes.map(tfName).join(", ")+(a.confirm_tf?" · ยืนยัน "+tfName(a.confirm_tf):"")+" · แจ้ง "+(al.length?al.join(" "):"ไม่มี");
}
function fixAsset(a){ // keep settings consistent with each other
 const maxTf=Math.max(0,...a.timeframes);
 if(a.confirm_tf&&a.confirm_tf<=maxTf){a.confirm_tf=0;return"ยกเลิก \"ยืนยันด้วย TF ใหญ่\" เพราะต้องใหญ่กว่าทุกไทม์เฟรมที่เลือก"}
 return"";
}
function renderAssets(){
 $("assets").innerHTML=cfg.assets.map((a,i)=>{const maxTf=Math.max(0,...a.timeframes);const sig=a.alerts.signal;
 return`<div class="asset ${a.enabled?"":"off"} ${openAsset===a.symbol?"open":""}" data-i="${i}">
 <div class="ahead"><label class="sw"><input type="checkbox" data-a="enabled" ${a.enabled?"checked":""}><i></i></label>
 <div class="info" data-act="toggle"><div><b>${esc(a.label)}</b> <span class="mut small">${esc(a.symbol)}</span></div><div class="sum">${esc(assetSummary(a))}</div></div>
 <span class="chev" data-act="toggle">›</span></div>
 <div class="abody">
 <div class="lbl">ไทม์เฟรม (แตะเพื่อเลือก ได้หลายอัน)</div>
 <div class="chips">${TFS.map(m=>`<button class="chip ${a.timeframes.includes(m)?"on":""}" data-tf="${m}">${tfName(m)}</button>`).join("")}</div>
 <div class="lbl">แจ้งเตือนอะไรบ้าง</div>
 <div class="chips">${Object.entries(ALERTS).map(([k,v])=>`<button class="chip ${a.alerts[k]?"on":""}" data-al="${k}" ${k!=="signal"&&!sig?"disabled":""}>${v}</button>`).join("")}</div>
 ${sig?"":`<div class="note warn">ปิด BUY/SELL แล้ว TP/SL จะไม่แจ้งด้วย (ไม่รู้ว่าเข้าออเดอร์ไหน)</div>`}
 <div class="lbl">ยืนยันด้วยเทรนด์ไทม์เฟรมใหญ่</div>
 <select data-a="confirm_tf" style="width:100%"><option value="0">ไม่ใช้</option>${TFS.filter(m=>m>maxTf).map(m=>`<option value="${m}" ${a.confirm_tf===m?"selected":""}>${tfName(m)} — BUY เฉพาะตอน ${tfName(m)} ขาขึ้น, SELL เฉพาะขาลง</option>`).join("")}</select>
 <div class="lbl">ชื่อที่แสดงในแจ้งเตือน</div>
 <input type="text" style="width:100%" data-a="label" value="${esc(a.label)}" maxlength="40">
 <button class="btn danger sm" data-act="del" style="margin-top:14px;width:100%">🗑 ลบ ${esc(a.label)}</button>
 </div></div>`}).join("")||`<div class="empty">ยังไม่มีสินทรัพย์ — เพิ่มด้านล่าง</div>`;
 const used=new Set(cfg.assets.map(a=>a.symbol));
 const sel=$("addSel"),cur=sel.value;
 sel.innerHTML=`<option value="">— เลือกสินทรัพย์ —</option>`+Object.entries(SYMS).filter(([k])=>!used.has(k)).map(([k,v])=>`<option value="${k}">${esc(v)} (${k})</option>`).join("")+`<option value="__custom">✏️ พิมพ์รหัสเอง…</option>`;
 if([...sel.options].some(o=>o.value===cur))sel.value=cur;
}
$("assets").addEventListener("click",e=>{const box=e.target.closest(".asset");if(!box)return;const a=cfg.assets[+box.dataset.i];const t=e.target.closest("button,[data-act]");if(!t)return;
 if(t.dataset.act==="toggle"){openAsset=openAsset===a.symbol?null:a.symbol;renderAssets();return}
 if(t.dataset.act==="del"){if(confirm("ลบ "+a.label+" ออกจากรายการ?")){cfg.assets.splice(+box.dataset.i,1);renderAssets();changed();toast("ลบแล้ว — กดบันทึกเพื่อยืนยัน")}return}
 if(t.dataset.tf){const m=+t.dataset.tf,j=a.timeframes.indexOf(m);j>=0?a.timeframes.splice(j,1):a.timeframes.push(m);a.timeframes.sort((x,y)=>x-y);const w=fixAsset(a);if(w)toast(w);renderAssets();changed();return}
 if(t.dataset.al){a.alerts[t.dataset.al]=!a.alerts[t.dataset.al];renderAssets();changed()}});
$("assets").addEventListener("change",e=>{const box=e.target.closest(".asset");if(!box)return;const a=cfg.assets[+box.dataset.i];const k=e.target.dataset.a;if(!k)return;
 if(k==="enabled")a.enabled=e.target.checked;else if(k==="confirm_tf")a.confirm_tf=+e.target.value;else if(k==="label")a.label=e.target.value.trim()||SYMS[a.symbol]||a.symbol;
 renderAssets();changed()});
$("addSel").onchange=()=>{$("addCodeRow").style.display=$("addSel").value==="__custom"?"":"none";if($("addSel").value==="__custom")$("addCode").focus()};
$("addBtn").onclick=()=>{let code=$("addSel").value;if(code==="__custom")code=$("addCode").value.trim();
 if(!code)return toast("เลือกสินทรัพย์ก่อน",1);
 if(!/^[A-Za-z0-9_]{2,30}$/.test(code))return toast("รหัสใช้ได้แค่ A-Z 0-9 และ _",1);
 if(cfg.assets.some(a=>a.symbol===code))return toast(code+" มีอยู่แล้ว",1);
 cfg.assets.push({symbol:code,label:SYMS[code]||code,enabled:true,timeframes:[15],confirm_tf:0,alerts:{signal:true,tp1:true,tp2:true,tp3:true,sl:true}});
 openAsset=code;$("addCode").value="";$("addSel").value="";$("addCodeRow").style.display="none";renderAssets();changed();toast("เพิ่ม "+(SYMS[code]||code)+" (15m) — ปรับได้ แล้วกดบันทึก")};

/* ---------- preview / test ---------- */
let pt=null;function preview(){clearTimeout(pt);pt=setTimeout(async()=>{try{
 const r=await (await fetch("/api/preview",{method:"POST",body:JSON.stringify(cfg)})).json();
 $("preview").innerHTML=["signal","tp","sl"].map(k=>`<div class="prev"><b>${esc(r[k][0])}</b>${esc(r[k][1])}</div>`).join("")}catch(e){}},250)}
$("testBtn").onclick=async e=>{const b=e.currentTarget;b.disabled=true;b.textContent="กำลังส่ง…";
 try{const r=await fetch("/api/test",{method:"POST",body:JSON.stringify(cfg)});toast(r.ok?"ส่งแล้ว — ดูที่แถบแจ้งเตือนของมือถือ":"ส่งไม่สำเร็จ",!r.ok)}catch(x){toast("ติดต่อบอทไม่ได้",1)}
 b.disabled=false;b.textContent="🧪 ส่งแจ้งเตือนทดสอบ";refresh()};

/* ---------- save / undo ---------- */
$("saveBtn").onclick=async()=>{const b=$("saveBtn");b.disabled=true;b.textContent="กำลังบันทึก…";
 try{const r=await fetch("/api/config",{method:"POST",body:JSON.stringify(cfg)});const j=await r.json();
  if(!r.ok)throw new Error(j.error);cfg=j.config;saved=JSON.stringify(cfg);fillBound();renderAssets();changed();toast("✅ บันทึกแล้ว มีผลทันที");setTimeout(refresh,1500)}
 catch(x){toast("บันทึกไม่สำเร็จ: "+(x.message||"ติดต่อบอทไม่ได้"),1)}
 b.disabled=false;b.textContent="💾 บันทึก"};
$("undoBtn").onclick=()=>{cfg=JSON.parse(saved);fillBound();renderAssets();changed();toast("ยกเลิกการแก้ไขแล้ว")};
addEventListener("beforeunload",e=>{if(cfg&&dirty()){e.preventDefault();e.returnValue=""}});
$("clearLog").onclick=async()=>{if(!confirm("ล้างรายการแจ้งเตือนล่าสุด?"))return;await fetch("/api/log/clear",{method:"POST"});refresh();toast("ล้างแล้ว")};

/* ---------- live status ---------- */
const adxWord=v=>v===""||v==="-"?"":+v<20?"ไซด์เวย์":+v<25?"เริ่มมีแรง":"มีเทรนด์";
function chartCard(s){
 if(s.error)return`<div class="chart"><div class="top"><span class="name">${esc(s.label)}<span class="tf">${tfName(s.tf)}</span></span></div><div class="note err">ดึงราคาไม่ได้: ${esc(s.error)}<br>ตรวจรหัสสินทรัพย์ในแท็บ 📈 สินทรัพย์</div></div>`;
 const t=s.trade;let tr="";
 if(t){const st=t.closed?'<span class="mut">จบแล้ว</span>':'<span class="pill UP" style="font-weight:600">กำลังติดตาม</span>';
  tr=`<div class="trade"><div class="row between"><span><span class="side ${t.side}">${t.side==="LONG"?"BUY":"SELL"}</span> <span class="mut small">เข้าแท่ง ${esc(t.time)}</span></span>${st}</div>
  <div class="lv"><div>เข้า<b>${esc(t.entry)}</b></div><div>SL<b class="neg">${esc(t.sl)}</b></div>${t.tps.map((p,k)=>`<div class="${t.tp_hit[k]?"hit":""}">TP${k+1}<b>${esc(p)}</b></div>`).join("")}</div></div>`}
 return`<div class="chart"><div class="top"><span class="name">${esc(s.label)}<span class="tf">${tfName(s.tf)}</span></span><span class="pill ${s.trend}">${s.trend==="UP"?"▲ ขาขึ้น":"▼ ขาลง"}</span></div>
 <div class="kv"><span class="mut">ราคา <b>${esc(s.close)}</b></span><span class="mut">ADX <b>${esc(s.adx)}</b> ${adxWord(s.adx)}</span><span class="mut">แท่งล่าสุด ${esc(s.candle)}</span></div>
 ${tr||'<div class="note mut">ยังไม่มีสัญญาณตั้งแต่เริ่มรัน</div>'}${s.filtered?`<div class="note warn">🧹 ${esc(s.filtered)}</div>`:""}</div>`;
}
function statsCard(s){const x=s.stats,cls=v=>v>0?"pos":v<0?"neg":"",sg=v=>(v>0?"+":"")+v.toFixed(2);
 return`<div class="card"><div class="row between"><b>${esc(s.label)} <span class="mut">${tfName(s.tf)}</span></b><span class="mut small">${x.days} วัน · ${esc(x.since)} – ${esc(x.until)}</span></div>
 <div class="sgrid"><div>สัญญาณ<b>${x.signals}</b></div><div>รู้ผลแล้ว<b>${x.closed}</b></div><div>อัตราชนะ<b>${x.win_rate===null?"-":x.win_rate.toFixed(1)+"%"}</b></div>
 <div>ชนะ<b class="pos">${x.wins}</b></div><div>แพ้<b class="neg">${x.losses}</b></div><div>กำไร<b class="${cls(x.profit_r)}">${sg(x.profit_r)}R</b></div></div>
 ${x.closed&&x.closed<30?`<div class="note warn">มีแค่ ${x.closed} เทรด ตัวเลขยังเชื่อไม่ได้มาก (ควร 30+)</div>`:""}
 ${x.open?'<div class="hint" style="margin:6px 0 0">+ 1 เทรดที่ยังเปิดอยู่ (ยังไม่นับ)</div>':""}
 <details><summary>ประวัติ 10 เทรดล่าสุด</summary><table><tr><th>เข้า</th><th>ฝั่ง</th><th>ผล</th><th>R</th></tr>
 ${x.history.map(h=>`<tr><td>${esc(h.time)}</td><td class="side ${h.side}">${h.side==="LONG"?"BUY":"SELL"}</td><td>${esc({SL:"โดน SL",REV:"กลับทิศ"}[h.outcome]||h.outcome)}</td><td class="${cls(h.r)}">${sg(h.r)}</td></tr>`).join("")||'<tr><td colspan="4" class="mut">ยังไม่มี</td></tr>'}</table></details></div>`}
async function refresh(){
 try{const r=await (await fetch("/api/status")).json();status=r;
  const rows=Object.values(r.status).sort((a,b)=>(a.label+a.tf).localeCompare(b.label+b.tf,undefined,{numeric:true}));
  const last=Math.max(0,...rows.map(s=>s.checked||0));
  $("dot").className="dot "+(last&&r.now-last<180?"ok":"bad");
  $("live").textContent=last?"เช็กล่าสุด "+ago(r.now-last)+"ที่แล้ว":"รอรอบแรก…";
  const empty=`<div class="empty">ยังไม่มีกราฟที่เปิดอยู่ — ไปที่ 📈 สินทรัพย์</div>`;
  $("charts").innerHTML=rows.length?rows.map(chartCard).join(""):(last?empty:'<div class="empty">กำลังโหลดราคารอบแรก…</div>');
  const st=rows.filter(s=>s.stats);$("stats").innerHTML=st.length?st.map(statsCard).join(""):(rows.length?'<div class="empty">กำลังคำนวณ…</div>':empty);
  $("log").innerHTML=r.log.length?r.log.slice(0,20).map(l=>`<div class="log"><span class="t">${new Date(l.time*1000).toLocaleString("th-TH",{day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"})}</span><b>${esc(l.title)}</b>${esc(l.body)}</div>`).join(""):'<div class="empty">ยังไม่มีแจ้งเตือน</div>';
 }catch(e){$("dot").className="dot bad";$("live").textContent="ติดต่อบอทไม่ได้";
  $("charts").innerHTML='<div class="note err">ติดต่อบอทไม่ได้ — บอทใน Termux ยังรันอยู่ไหม?</div>'}
}
async function load(){
 const r=await (await fetch("/api/config")).json();cfg=r.config;saved=JSON.stringify(cfg);SYMS=r.symbols;TFS=r.timeframes;
 fillBound();renderAssets();changed();
}
let t0="ov";try{t0=localStorage.getItem("tab")||"ov"}catch(e){}
if(!$(t0))t0="ov";tab(t0);
load().catch(()=>toast("โหลดการตั้งค่าไม่ได้",1));refresh();setInterval(refresh,10000);
</script></body></html>
"""


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
def run_test(cfg):
    deriv = Deriv(cfg)
    print("Deriv API limits:", json.dumps(deriv.api_limits(), indent=1))
    for asset, tf in watch_pairs(cfg):
        gran = tf * 60
        try:
            candles = deriv.closed_candles(asset["symbol"], gran, cfg["candles"])
        except DerivSymbolError as exc:
            print("%s [%dm]: ERROR %s" % (asset["symbol"], tf, exc))
            continue
        highs = [c["high"] for c in candles]
        lows = [c["low"] for c in candles]
        closes = [c["close"] for c in candles]
        s = cfg["strategy"]
        _, direction, atr = supertrend(highs, lows, closes, s["supertrend_factor"], s["atr_period"])
        last_sig = None
        for i in range(1, len(candles)):
            side = signal_at(direction, i)
            if side:
                last_sig = make_trade(side, candles[i], atr[i], s, price_digits(candles))
        trend = "UP" if direction[-1] == -1 else "DOWN"
        print("%s (%s) [%dm]: %d candles, trend now %s, close %s" % (
            asset["label"], asset["symbol"], tf, len(candles), trend, fmt(closes[-1])))
        if last_sig:
            title, body = signal_message(asset, tf, last_sig, cfg)
            print("  Last signal (history):", title, "|", body.replace("\n", " | "))
    deriv.close()
    n = cfg["notify"]
    notify(cfg, "🧪 ทดสอบ: บอทแจ้งเตือนทำงานปกติ", "ถ้าเห็นข้อความนี้ แปลว่าตั้งค่าแจ้งเตือนถูกต้องแล้ว",
           n["signal_sound"], "ทดสอบ" if n["tts_lang"] == "th" else "Test")


def main():
    if websocket is None:
        sys.exit("Missing package. Run:  pip install websocket-client")
    cfg = load_config()
    if not os.path.exists(CONFIG_PATH):
        save_config(cfg)
    if "--test" in sys.argv:
        run_test(cfg)
        return
    shared = Shared(cfg)
    print("Watching: %s" % ", ".join("%s %dm" % (a["label"], tf) for a, tf in watch_pairs(cfg)), flush=True)
    if "--no-dashboard" not in sys.argv:
        try:
            url = start_dashboard(shared)
            print("Dashboard: %s  (open in Chrome on this phone)" % url, flush=True)
        except OSError as exc:
            print("Dashboard not started: %s" % exc, flush=True)
    print("Ctrl+C to stop.", flush=True)
    try:
        run_loop(shared)
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
