#!/data/data/com.termux/files/usr/bin/bash
# One-time setup for the Deriv signal bot in Termux.
set -e
pkg update -y
pkg install -y python termux-api
pip install --upgrade websocket-client
cd "$(dirname "$0")"
[ -f config.json ] || cp config.example.json config.json
echo
echo "Done. Next:"
echo "  1) (optional) edit config.json  ->  nano config.json"
echo "  2) test:  python deriv_signal_bot.py --test"
echo "  3) run:   termux-wake-lock && python deriv_signal_bot.py"
