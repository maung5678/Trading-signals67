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
        {"symbol": "cryBTCUSD", "label": "BTCUSD", "enabled": True, "timeframes": [1], "alerts": dict(DEFAULT_ALERTS)},
        {"symbol": "CRASH1000", "label": "Crash 1000 Index", "enabled": True, "timeframes": [15], "alerts": dict(DEFAULT_ALERTS)},
        {"symbol": "BOOM1000", "label": "Boom 1000 Index", "enabled": True, "timeframes": [15], "alerts": dict(DEFAULT_ALERTS)},
    ],
    "strategy": {"supertrend_factor": 2.5, "atr_period": 14, "sl_atr_mult": 1.5, "tp_rr": [1.0, 2.0, 3.0]},
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
        "telegram_bot_token": "",
        "telegram_chat_id": "",
    },
    "poll_seconds": 20,
    "candles": 300,
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
    raw["strategy"] = _merge(legacy_strategy, raw.get("strategy", {}))

    cfg = _merge(DEFAULT_CONFIG, {k: v for k, v in raw.items() if k != "assets"})
    if "assets" in raw:
        cfg["assets"] = raw["assets"]

    assets, seen = [], set()
    for a in cfg["assets"]:
        sym = str(a.get("symbol", "")).strip()
        if not re.fullmatch(r"[A-Za-z0-9_]{2,30}", sym) or sym in seen:
            continue
        seen.add(sym)
        tfs = sorted({int(t) for t in a.get("timeframes", []) if int(t) in TIMEFRAMES})
        assets.append({
            "symbol": sym,
            "label": str(a.get("label") or KNOWN_SYMBOLS.get(sym, sym))[:40],
            "enabled": bool(a.get("enabled", True)),
            "timeframes": tfs,
            "alerts": _merge(DEFAULT_ALERTS, {k: bool(v) for k, v in (a.get("alerts") or {}).items() if k in DEFAULT_ALERTS}),
        })
    cfg["assets"] = assets

    s = cfg["strategy"]
    s["supertrend_factor"] = min(max(float(s["supertrend_factor"]), 0.1), 20.0)
    s["atr_period"] = min(max(int(s["atr_period"]), 1), 100)
    s["sl_atr_mult"] = min(max(float(s["sl_atr_mult"]), 0.1), 20.0)
    s["tp_rr"] = [min(max(float(x), 0.1), 50.0) for x in list(s["tp_rr"])[:3]] or [1.0, 2.0, 3.0]
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
    cfg["poll_seconds"] = min(max(int(cfg["poll_seconds"]), 5), 300)
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
    return ("BUY", "Long") if side == "LONG" else ("SELL", "Short")


def signal_message(asset, tf, trade, cfg, late=False):
    n = cfg["notify"]
    f = n["fields"]
    buy_sell, long_short = side_words(trade["side"])
    icon = ("🟢 " if trade["side"] == "LONG" else "🔴 ") if n["emoji"] else ""
    title = "%s%s (%s) %s [%dm]%s" % (icon, buy_sell, long_short, asset["label"], tf, " (late)" if late else "")
    parts = []
    if f.get("entry"):
        parts.append(("Entry", fmt(trade["entry"], trade.get("digits"))))
    if f.get("sl"):
        sl_text = fmt(trade["sl"], trade.get("digits"))
        if f.get("risk"):
            sl_text += " (risk %s)" % fmt(abs(trade["entry"] - trade["sl"]), trade.get("digits"))
        parts.append(("SL", sl_text))
    for k, tp in enumerate(trade["tps"]):
        if f.get("tp%d" % (k + 1)):
            parts.append(("TP%d" % (k + 1), fmt(tp, trade.get("digits"))))
    if f.get("time"):
        parts.append(("Time", fmt_time(trade["epoch"] + tf * 60, cfg)))
    if n["style"] == "compact":
        body = " | ".join("%s %s" % p for p in parts)
    else:
        body = "\n".join("%s: %s" % p for p in parts)
    return title, body


def event_message(asset, tf, trade, event, cfg):
    emoji = cfg["notify"]["emoji"]
    buy_sell, _ = side_words(trade["side"])
    if event == "SL":
        title = "%sSL hit %s [%dm]" % ("⛔ " if emoji else "", asset["label"], tf)
        body = "%s trade stopped at SL %s" % (buy_sell, fmt(trade["sl"], trade.get("digits")))
    else:
        k = int(event[2:]) - 1
        title = "%s%s reached %s [%dm]" % ("✅ " if emoji else "", event, asset["label"], tf)
        body = "%s trade: %s %s" % (buy_sell, event, fmt(trade["tps"][k], trade.get("digits")))
        if k == 0 and len(trade["tps"]) > 1:
            body += " (consider moving SL to entry %s)" % fmt(trade["entry"], trade.get("digits"))
    return title, body


def speech_text(asset, tf, kind, cfg):
    th = cfg["notify"]["tts_lang"] == "th"
    if kind in ("LONG", "SHORT"):
        word = ("ซื้อ" if kind == "LONG" else "ขาย") if th else ("Buy" if kind == "LONG" else "Sell")
    elif kind == "SL":
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
    if n.get("telegram_bot_token") and n.get("telegram_chat_id"):
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


def process(deriv, cfg, state, asset, tf, shared=None):
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
    digits = price_digits(candles)
    if shared is not None:
        shared.set_status(key, symbol=symbol, label=asset["label"], tf=tf, checked=time.time(),
                          candle=fmt_time(candles[-1]["epoch"] + gran, cfg), close=fmt(closes[-1]),
                          trend="UP" if direction[-1] == -1 else "DOWN", error="")
    st = state.setdefault(key, {"last_epoch": 0, "trade": None})
    if candles[-1]["epoch"] <= st["last_epoch"]:
        return  # no new closed candle yet
    first_run = st["last_epoch"] == 0

    # Walk every candle that closed since the last check (the phone may have slept).
    for i, candle in enumerate(candles):
        if candle["epoch"] <= st["last_epoch"]:
            continue
        side = signal_at(direction, i)
        if side:
            st["trade"] = make_trade(side, candle, atr[i], strategy, digits)
            if not first_run and alerts["signal"]:
                title, body = signal_message(asset, tf, st["trade"], cfg, late=i < len(candles) - 1)
                notify(cfg, title, body, n["signal_sound"], speech_text(asset, tf, side, cfg), symbol, shared)
            continue
        if first_run:
            continue
        for ev in update_trade(st["trade"], candle):
            if alerts.get(ev.lower()):
                title, body = event_message(asset, tf, st["trade"], ev, cfg)
                notify(cfg, title, body, n["tpsl_sound"], speech_text(asset, tf, ev, cfg), symbol, shared)
    st["last_epoch"] = candles[-1]["epoch"]
    if shared is not None and st.get("trade"):
        t = st["trade"]
        shared.set_status(key, trade="%s @ %s, SL %s, TP %s" % (
            side_words(t["side"])[0], fmt(t["entry"], t.get("digits")), fmt(t["sl"], t.get("digits")),
            " / ".join(fmt(x, t.get("digits")) for x in t["tps"])))


def run_loop(shared):
    state = load_state()
    cfg = shared.get_cfg()
    deriv = Deriv(cfg)
    backoff = 5
    while True:
        cfg = shared.get_cfg()
        try:
            for asset, tf in watch_pairs(cfg):
                key = "%s_%d" % (asset["symbol"], tf)
                try:
                    process(deriv, cfg, state, asset, tf, shared)
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
            try:
                cfg = normalize_config(self._body())
            except Exception as exc:
                self._send(400, {"error": "invalid settings: %s" % exc})
                return
            asset = cfg["assets"][0] if cfg["assets"] else {"symbol": "cryBTCUSD", "label": "BTCUSD"}
            tf = (asset.get("timeframes") or [1])[0]
            trade = sample_trade(cfg)
            sig = signal_message(asset, tf, trade, cfg)
            tp = event_message(asset, tf, trade, "TP1", cfg)
            if path == "/api/config":
                shared.set_cfg(cfg)
                self._send(200, {"ok": True, "config": cfg})
            elif path == "/api/preview":
                self._send(200, {"signal": sig, "tp": tp})
            elif path == "/api/test":
                n = cfg["notify"]
                notify(cfg, "🧪 TEST " + sig[0], sig[1], n["signal_sound"],
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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Signal Bot Settings</title>
<style>
:root{--bg:#0f1115;--card:#181b22;--line:#2a2f3a;--fg:#e8eaed;--mut:#9aa0aa;--acc:#3b82f6;--up:#16a34a;--dn:#dc2626}
@media (prefers-color-scheme: light){:root{--bg:#f4f5f7;--card:#fff;--line:#dfe2e7;--fg:#15171a;--mut:#5f6670}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,sans-serif;padding:0 14px 90px}
h1{font-size:20px;margin:16px 0 4px}h2{font-size:16px;margin:0 0 10px}
.mut{color:var(--mut);font-size:13px}.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin:12px 0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.between{justify-content:space-between}
label.t{display:inline-flex;gap:6px;align-items:center;margin:4px 12px 4px 0}
input[type=text],input[type=number],input[type=password],select{background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:8px;padding:8px;font:inherit;min-width:0}
input[type=number]{width:80px}.grow{flex:1}
.chip{border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:999px;padding:6px 11px;font:inherit;font-size:14px}
.chip.on{background:var(--acc);border-color:var(--acc);color:#fff}
button{cursor:pointer}.btn{border:0;border-radius:10px;padding:11px 16px;font:inherit;font-weight:600;background:var(--acc);color:#fff}
.btn.sec{background:var(--line);color:var(--fg)}.btn.del{background:transparent;color:var(--dn);border:1px solid var(--dn);padding:6px 10px}
.asset{border-top:1px solid var(--line);padding:12px 0}.asset:first-of-type{border-top:0}
.sym{font-weight:700}.code{font-family:ui-monospace,monospace;font-size:12px;color:var(--mut)}
.prev{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:10px;white-space:pre-wrap;font-size:14px;margin-top:8px}
.prev b{display:block;margin-bottom:4px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:10px 14px;display:flex;gap:8px}
.bar .btn{flex:1}.ok{color:var(--up)}.err{color:var(--dn)}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:5px 4px;border-bottom:1px solid var(--line);vertical-align:top}
.UP{color:var(--up);font-weight:600}.DOWN{color:var(--dn);font-weight:600}
details summary{cursor:pointer;font-weight:600}
</style></head><body>
<h1>⚙️ Signal Bot</h1>
<div class="mut" id="msg">กำลังโหลด…</div>

<div class="card"><h2>📊 สถานะ</h2><div id="status" class="mut">-</div>
<details style="margin-top:10px"><summary>แจ้งเตือนล่าสุด</summary><div id="log" class="mut"></div></details></div>

<div class="card"><h2>📈 สินทรัพย์ &amp; ไทม์เฟรม</h2>
<div class="mut">แตะไทม์เฟรมเพื่อเปิด/ปิด · ติ๊กเลือกว่าจะให้แจ้งอะไรบ้าง</div>
<div id="assets"></div>
<div class="row" style="margin-top:10px">
<select id="addSel" class="grow"></select><button class="btn sec" onclick="addAsset()">+ เพิ่ม</button></div>
<div class="row" style="margin-top:6px">
<input type="text" id="addCode" class="grow" placeholder="หรือพิมพ์รหัส Deriv เอง เช่น R_50"></div></div>

<div class="card"><h2>💬 หน้าตาการแจ้งเตือน</h2>
<div class="row"><label class="t"><input type="radio" name="style" value="detailed"> แบบละเอียด (หลายบรรทัด)</label>
<label class="t"><input type="radio" name="style" value="compact"> แบบย่อ (บรรทัดเดียว)</label></div>
<div class="mut" style="margin-top:6px">แสดงข้อมูล:</div><div class="row" id="fields"></div>
<label class="t"><input type="checkbox" id="emoji"> ใส่อีโมจิ 🟢🔴✅⛔</label>
<div class="row"><span>ความสำคัญ</span><select id="priority">
<option value="max">สูงสุด (เด้งบนจอ)</option><option value="high">สูง</option><option value="default">ปกติ</option><option value="low">ต่ำ (เงียบ)</option></select>
<span>สีไฟ LED</span><input type="color" id="led"></div>
<div class="prev" id="preview">-</div></div>

<div class="card"><h2>🔔 เสียง &amp; การสั่น</h2>
<div class="row"><span style="width:120px">สัญญาณ BUY/SELL</span><select id="sigSound" class="grow"></select></div>
<div class="row" style="margin-top:6px"><span style="width:120px">TP / SL</span><select id="tpsSound" class="grow"></select></div>
<div class="row" style="margin-top:6px"><span style="width:120px">ภาษาเสียงพูด</span><select id="tts"><option value="th">ไทย</option><option value="en">English</option></select></div>
<div class="row" style="margin-top:6px"><span style="width:120px">ไฟล์เสียง</span><input type="text" id="sfile" class="grow" placeholder="~/storage/downloads/alert.mp3"></div>
<div class="row" style="margin-top:6px"><span style="width:120px">การสั่น</span><select id="vib" class="grow">
<option value="">ไม่สั่น</option><option value="300">สั้น</option><option value="500,200,500">2 ครั้ง</option>
<option value="800,200,800,200,800">3 ครั้งยาว</option></select></div></div>

<div class="card"><details><summary>📨 Telegram (ไม่บังคับ)</summary>
<div class="row" style="margin-top:8px"><input type="password" id="tgToken" class="grow" placeholder="Bot token"></div>
<div class="row" style="margin-top:6px"><input type="text" id="tgChat" class="grow" placeholder="chat_id"></div>
<label class="t"><input type="checkbox" id="termux"> เด้งแจ้งเตือนในมือถือ (Termux:API)</label></details></div>

<div class="card"><details><summary>🧮 ค่าการคำนวณ (ให้ตรงกับอินดิเคเตอร์)</summary>
<div class="row" style="margin-top:8px"><span>Supertrend factor</span><input type="number" step="0.1" id="factor">
<span>ATR</span><input type="number" id="atr"></div>
<div class="row" style="margin-top:6px"><span>SL = ATR ×</span><input type="number" step="0.1" id="slm"></div>
<div class="row" style="margin-top:6px"><span>TP1 R</span><input type="number" step="0.1" id="tp1">
<span>TP2 R</span><input type="number" step="0.1" id="tp2"><span>TP3 R</span><input type="number" step="0.1" id="tp3"></div>
<div class="row" style="margin-top:6px"><span>เช็กราคาทุก (วินาที)</span><input type="number" id="poll"></div></details></div>

<div class="bar"><button class="btn sec" onclick="testN()">🧪 ทดสอบแจ้งเตือน</button><button class="btn" onclick="save()">💾 บันทึก</button></div>

<script>
let cfg=null, SYMS={}, TFS=[];
const $=id=>document.getElementById(id);
const FIELDS={entry:"Entry",sl:"SL",risk:"ระยะ SL",tp1:"TP1",tp2:"TP2",tp3:"TP3",time:"เวลา"};
const ALERTS={signal:"BUY/SELL",tp1:"TP1",tp2:"TP2",tp3:"TP3",sl:"SL"};
const SOUNDS={system:"เสียงแจ้งเตือนของเครื่อง",tts:"พูดออกเสียง (เช่น 'ซื้อ BTCUSD')",file:"ไฟล์เสียงของฉัน",none:"ไม่มีเสียง"};
const tfName=m=>m<60?m+"m":m<1440?(m/60)+"h":"1D";
function esc(s){return String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
function msg(t,cls){$("msg").className="mut "+(cls||"");$("msg").textContent=t}

async function load(){
  const r=await (await fetch("/api/config")).json(); cfg=r.config; SYMS=r.symbols; TFS=r.timeframes;
  for(const s of ["sigSound","tpsSound"]) $(s).innerHTML=Object.entries(SOUNDS).map(([k,v])=>`<option value="${k}">${v}</option>`).join("");
  $("fields").innerHTML=Object.entries(FIELDS).map(([k,v])=>`<label class="t"><input type="checkbox" data-f="${k}" onchange="sync()"> ${v}</label>`).join("");
  fill(); renderAssets(); msg("แก้ไขได้เลย แล้วกด 💾 บันทึก — มีผลทันที ไม่ต้องรีสตาร์ทบอท");
}
function fill(){
  const n=cfg.notify,s=cfg.strategy;
  document.querySelectorAll("input[name=style]").forEach(r=>r.checked=r.value===n.style);
  document.querySelectorAll("[data-f]").forEach(c=>c.checked=!!n.fields[c.dataset.f]);
  $("emoji").checked=n.emoji;$("priority").value=n.priority;$("led").value="#"+n.led_color;
  $("sigSound").value=n.signal_sound;$("tpsSound").value=n.tpsl_sound;$("tts").value=n.tts_lang;$("sfile").value=n.sound_file;
  $("vib").value=n.vibrate; if($("vib").value!==n.vibrate){$("vib").insertAdjacentHTML("beforeend",`<option value="${esc(n.vibrate)}">${esc(n.vibrate)}</option>`);$("vib").value=n.vibrate}
  $("tgToken").value=n.telegram_bot_token;$("tgChat").value=n.telegram_chat_id;$("termux").checked=n.termux;
  $("factor").value=s.supertrend_factor;$("atr").value=s.atr_period;$("slm").value=s.sl_atr_mult;
  [1,2,3].forEach(i=>$("tp"+i).value=s.tp_rr[i-1]);$("poll").value=cfg.poll_seconds;
  document.querySelectorAll("input,select").forEach(e=>{if(!e.dataset.bound){e.dataset.bound=1;e.addEventListener("change",sync)}});
  preview();
}
function sync(){
  const n=cfg.notify,s=cfg.strategy;
  n.style=(document.querySelector("input[name=style]:checked")||{}).value||"detailed";
  document.querySelectorAll("[data-f]").forEach(c=>n.fields[c.dataset.f]=c.checked);
  n.emoji=$("emoji").checked;n.priority=$("priority").value;n.led_color=$("led").value.replace("#","");
  n.signal_sound=$("sigSound").value;n.tpsl_sound=$("tpsSound").value;n.tts_lang=$("tts").value;n.sound_file=$("sfile").value.trim();
  n.vibrate=$("vib").value;n.telegram_bot_token=$("tgToken").value.trim();n.telegram_chat_id=$("tgChat").value.trim();n.termux=$("termux").checked;
  s.supertrend_factor=+$("factor").value;s.atr_period=+$("atr").value;s.sl_atr_mult=+$("slm").value;
  s.tp_rr=[1,2,3].map(i=>+$("tp"+i).value);cfg.poll_seconds=+$("poll").value;
  preview();
}
function renderAssets(){
  $("assets").innerHTML=cfg.assets.map((a,i)=>`
  <div class="asset"><div class="row between"><label class="t"><input type="checkbox" ${a.enabled?"checked":""} onchange="cfg.assets[${i}].enabled=this.checked">
  <span><span class="sym">${esc(a.label)}</span> <span class="code">${esc(a.symbol)}</span></span></label>
  <button class="btn del" onclick="delAsset(${i})">ลบ</button></div>
  <div class="row" style="margin:6px 0">${TFS.map(m=>`<button class="chip ${a.timeframes.includes(m)?"on":""}" onclick="toggleTf(${i},${m})">${tfName(m)}</button>`).join("")}</div>
  <div class="row">${Object.entries(ALERTS).map(([k,v])=>`<label class="t"><input type="checkbox" ${a.alerts[k]?"checked":""} onchange="cfg.assets[${i}].alerts['${k}']=this.checked"> ${v}</label>`).join("")}</div>
  <div class="row"><span class="mut">ชื่อที่แสดง</span><input type="text" class="grow" value="${esc(a.label)}" onchange="cfg.assets[${i}].label=this.value;renderAssets();preview()"></div></div>`).join("")
  || `<div class="mut">ยังไม่มีสินทรัพย์</div>`;
  const used=new Set(cfg.assets.map(a=>a.symbol));
  $("addSel").innerHTML=`<option value="">— เลือกสินทรัพย์ —</option>`+Object.entries(SYMS).filter(([k])=>!used.has(k)).map(([k,v])=>`<option value="${k}">${esc(v)} (${k})</option>`).join("");
}
function toggleTf(i,m){const t=cfg.assets[i].timeframes;const j=t.indexOf(m);j>=0?t.splice(j,1):t.push(m);t.sort((a,b)=>a-b);renderAssets()}
function delAsset(i){if(confirm("ลบ "+cfg.assets[i].label+" ?")){cfg.assets.splice(i,1);renderAssets()}}
function addAsset(){
  const code=($("addCode").value.trim()||$("addSel").value);
  if(!code)return msg("เลือกหรือพิมพ์รหัสสินทรัพย์ก่อน","err");
  if(cfg.assets.some(a=>a.symbol===code))return msg(code+" มีอยู่แล้ว","err");
  cfg.assets.push({symbol:code,label:SYMS[code]||code,enabled:true,timeframes:[15],alerts:{signal:true,tp1:true,tp2:true,tp3:true,sl:true}});
  $("addCode").value="";renderAssets();msg("เพิ่ม "+code+" แล้ว (ค่าเริ่มต้น 15m) — อย่าลืมกดบันทึก","ok");
}
let pt=null;function preview(){clearTimeout(pt);pt=setTimeout(async()=>{
  const r=await (await fetch("/api/preview",{method:"POST",body:JSON.stringify(cfg)})).json();
  $("preview").innerHTML=`<span class="mut">ตัวอย่าง:</span>\n<b>${esc(r.signal[0])}</b>${esc(r.signal[1])}\n\n<b>${esc(r.tp[0])}</b>${esc(r.tp[1])}`;},250)}
async function save(){
  const r=await fetch("/api/config",{method:"POST",body:JSON.stringify(cfg)});const j=await r.json();
  if(!r.ok)return msg(j.error||"บันทึกไม่สำเร็จ","err");
  cfg=j.config;fill();renderAssets();msg("✅ บันทึกแล้ว "+new Date().toLocaleTimeString(),"ok");refresh();
}
async function testN(){await fetch("/api/test",{method:"POST",body:JSON.stringify(cfg)});msg("ส่งแจ้งเตือนทดสอบแล้ว (ใช้ค่าบนหน้านี้ ยังไม่ได้บันทึก)","ok");setTimeout(refresh,800)}
async function refresh(){
  try{const r=await (await fetch("/api/status")).json();
  const rows=Object.values(r.status).sort((a,b)=>(a.label+a.tf).localeCompare(b.label+b.tf));
  $("status").innerHTML=rows.length?`<table><tr><th>สินทรัพย์</th><th>เทรนด์</th><th>เช็กล่าสุด</th></tr>`+rows.map(s=>`<tr><td><b>${esc(s.label)}</b> ${tfName(s.tf)}${s.trade?`<div class="mut">${esc(s.trade)}</div>`:""}</td>
   <td>${s.error?`<span class="err">${esc(s.error)}</span>`:`<span class="${s.trend}">${s.trend==="UP"?"▲ ขึ้น":"▼ ลง"}</span><div class="mut">${esc(s.close||"")}</div>`}</td>
   <td>${Math.round(r.now-s.checked)} วิ<div class="mut">แท่ง ${esc(s.candle||"-")}</div></td></tr>`).join("")+`</table>`:"รอรอบแรก…";
  $("log").innerHTML=r.log.length?r.log.map(l=>`<div class="prev"><span class="mut">${new Date(l.time*1000).toLocaleString()}</span>\n<b>${esc(l.title)}</b>${esc(l.body)}</div>`).join(""):"ยังไม่มี";
  }catch(e){$("status").innerHTML='<span class="err">ติดต่อบอทไม่ได้ — บอทใน Termux ยังรันอยู่ไหม?</span>'}
}
load();refresh();setInterval(refresh,10000);
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
    notify(cfg, "🧪 Test: signal bot is working", "If you see this, notifications are set up correctly.",
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
