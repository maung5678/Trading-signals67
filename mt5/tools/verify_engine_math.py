#!/usr/bin/env python3
"""Check the indicator's incremental math against the bot's batch math.

run() below mirrors CEngine.Step() of mt5/Indicators/ST_TP_SL.mq5 line by line
(ATR, Supertrend and ADX computed one candle at a time with SMA seeding).
It is compared with the functions of bot/deriv_signal_bot.py, which follow
TradingView ta.atr / ta.supertrend / ta.dmi, on random price data.
Keep run() in sync when CEngine.Step() changes:

    python3 mt5/tools/verify_engine_math.py
"""
import random
import importlib.util
from pathlib import Path

BOT = Path(__file__).resolve().parents[2] / "bot" / "deriv_signal_bot.py"
spec = importlib.util.spec_from_file_location("bot", BOT)
bot = importlib.util.module_from_spec(spec); spec.loader.exec_module(bot)
E = None
def run(h, l, c, first, F=2.5, P=14, L=14, S=14):
    n = len(c)
    atr=[E]*n; up=[E]*n; lo=[E]*n; st=[E]*n; d=[0]*n; trur=[E]*n; ps=[E]*n; ms=[E]*n; dx=[E]*n; ar=[E]*n; adx=[E]*n
    def tr(i):
        if i <= first: return h[i]-l[i]
        return max(h[i]-l[i], abs(h[i]-c[i-1]), abs(l[i]-c[i-1]))
    def pdm(i):
        u, dn = h[i]-h[i-1], l[i-1]-l[i]; return u if (u > dn and u > 0) else 0.0
    def mdm(i):
        u, dn = h[i]-h[i-1], l[i-1]-l[i]; return dn if (dn > u and dn > 0) else 0.0
    for i in range(first, n):
        k = i-first
        a = E
        if k == P-1: a = sum(tr(j) for j in range(i-P+1, i+1))/P
        elif k >= P and atr[i-1] is not E: a = (atr[i-1]*(P-1)+tr(i))/P
        atr[i] = a
        dd = 0; s1 = E
        if a is not E:
            upP = up[i-1] if (k > 0 and up[i-1] is not E) else 0.0
            loP = lo[i-1] if (k > 0 and lo[i-1] is not E) else 0.0
            src = (h[i]+l[i])/2; u = src+F*a; w = src-F*a
            pc = c[i-1] if k > 0 else c[i]
            w = w if (w > loP or pc < loP) else loP
            u = u if (u < upP or pc > upP) else upP
            if k == 0 or atr[i-1] is E: dd = 1
            elif st[i-1] == up[i-1]: dd = -1 if c[i] > u else 1
            else: dd = 1 if c[i] < w else -1
            s1 = w if dd == -1 else u; up[i] = u; lo[i] = w
        st[i] = s1; d[i] = dd
        t1 = p1 = m1 = E
        if k == L-1: t1 = sum(tr(j) for j in range(i-L+1, i+1))/L
        elif k >= L and trur[i-1] is not E: t1 = (trur[i-1]*(L-1)+tr(i))/L
        if k == L:
            p1 = sum(pdm(j) for j in range(i-L+1, i+1))/L; m1 = sum(mdm(j) for j in range(i-L+1, i+1))/L
        elif k > L and ps[i-1] is not E:
            p1 = (ps[i-1]*(L-1)+pdm(i))/L; m1 = (ms[i-1]*(L-1)+mdm(i))/L
        trur[i]=t1; ps[i]=p1; ms[i]=m1
        x = E
        if t1 is not E and p1 is not E:
            if t1 == 0: x = 0.0
            else:
                pdi, mdi = 100*p1/t1, 100*m1/t1; sm = pdi+mdi; x = abs(pdi-mdi)/(sm if sm != 0 else 1)
        dx[i] = x
        r = E
        if k == L+S-1:
            vals = dx[i-S+1:i+1]
            if all(v is not E for v in vals): r = sum(vals)/S
        elif k > L+S-1 and ar[i-1] is not E:
            r = ar[i-1] if x is E else (ar[i-1]*(S-1)+x)/S
        ar[i] = r; adx[i] = E if r is E else 100*r
    return atr, st, d, adx

random.seed(7)
worst = 0.0; mism = 0; sigs = 0
for trial in range(30):
    n = 1500; price = 2000.0; h=[]; l=[]; c=[]; o=[]
    for i in range(n):
        op = price; cl = op + random.gauss(0, 3); hi = max(op, cl) + abs(random.gauss(0, 1.5)); lw = min(op, cl) - abs(random.gauss(0, 1.5))
        o.append(op); h.append(hi); l.append(lw); c.append(cl); price = cl
    atr, st, d, adx = run(h, l, c, 0)
    bst, bdir, batr = bot.supertrend(h, l, c, 2.5, 14)
    _, _, badx = bot.adx_dmi(h, l, c, 14, 14)
    for i in range(n):
        if (atr[i] is None) != (batr[i] is None) or (d[i] or None) != bdir[i] or (adx[i] is None) != (badx[i] is None):
            mism += 1; continue
        if atr[i] is not None:
            worst = max(worst, abs(atr[i]-batr[i]), abs(st[i]-bst[i]))
        if adx[i] is not None:
            worst = max(worst, abs(adx[i]-badx[i]))
        if i and bot.signal_at(bdir, i) is not None:
            sigs += 1
print("bars compared:", 30 * 1500, "mismatched bars:", mism, "max abs diff:", worst, "signals:", sigs)
if mism or worst > 1e-9:
    raise SystemExit("FAILED")
print("OK")
