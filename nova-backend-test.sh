#!/usr/bin/env bash
# =============================================================================
#  Nova Backend — connectivity tester
#  Checks, from the OUTSIDE, whether your Xray backend is reachable and speaks
#  WebSocket on the path Nova will forward to. Run it from your laptop (best,
#  proves the firewall is open to the world) or from the VPS itself.
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/IRNova/Tools/main/nova-backend-test.sh) 76.13.79.199 10000 /novavpn
#
#  Args:  <VPS_IP>  <PORT>  <PATH>      (defaults: 10000  /novavpn)
# =============================================================================
set -uo pipefail

c_grn=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
ok(){ printf '%s\n' "${c_grn}✓${c_rst} $*"; }
no(){ printf '%s\n' "${c_red}✗${c_rst} $*"; }
hm(){ printf '%s\n' "${c_yel}…${c_rst} $*"; }
hd(){ printf '\n%s\n' "${c_cyn}${c_bld}== $* ==${c_rst}"; }

IP="${1:-}"; PORT="${2:-10000}"; WPATH="${3:-/novavpn}"
[ "${WPATH:0:1}" = "/" ] || WPATH="/$WPATH"
if [ -z "$IP" ]; then
  echo "Usage: $0 <VPS_IP> [PORT] [PATH]"
  echo "   e.g: $0 76.13.79.199 10000 /novavpn"
  exit 1
fi

echo "${c_bld}Nova backend tester${c_rst}"
echo "  target: ${c_cyn}${IP}:${PORT}${WPATH}${c_rst}"

PASS=1

# ---- 1) TCP port open? -------------------------------------------------------
hd "1) Is the port open (TCP reachable)?"
if command -v nc >/dev/null 2>&1; then
  if nc -z -w5 "$IP" "$PORT" 2>/dev/null; then
    ok "Port ${PORT} is OPEN and reachable from here."
  else
    no "Port ${PORT} is CLOSED or filtered from here."
    echo "   → Almost always your cloud provider's firewall / security group."
    echo "     Allow inbound ${c_bld}TCP ${PORT}${c_rst} in the provider dashboard (separate from ufw)."
    PASS=0
  fi
else
  hm "nc (netcat) not installed — trying bash /dev/tcp..."
  if timeout 5 bash -c "echo > /dev/tcp/${IP}/${PORT}" 2>/dev/null; then
    ok "Port ${PORT} is OPEN (via /dev/tcp)."
  else
    no "Port ${PORT} appears CLOSED/filtered (via /dev/tcp)."
    echo "   → Open inbound TCP ${PORT} in your VPS provider's firewall."
    PASS=0
  fi
fi

# ---- 2) WebSocket upgrade on the path? --------------------------------------
hd "2) Does it speak WebSocket on ${WPATH}? (this is what Nova forwards)"
# Send a real WS upgrade handshake. Xray should answer 101 Switching Protocols.
# A 400 to a PLAIN GET is normal; here we send the upgrade headers it expects.
KEY="dGhlIHNhbXBsZSBub25jZQ=="   # standard example Sec-WebSocket-Key
RESP="$(curl -s -i --max-time 8 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: ${KEY}" \
  "http://${IP}:${PORT}${WPATH}" 2>/dev/null | head -20)"

if printf '%s' "$RESP" | grep -qi "101"; then
  ok "Got ${c_bld}101 Switching Protocols${c_rst} — Xray WebSocket is ALIVE on ${WPATH}. 🎉"
elif printf '%s' "$RESP" | grep -qiE "400|404|426"; then
  CODE="$(printf '%s' "$RESP" | head -1)"
  no "Got: ${CODE}"
  echo "   → The port is open but Xray did not upgrade on ${WPATH}."
  echo "     Likely a ${c_bld}PATH mismatch${c_rst}: the path here must match the wsSettings.path in"
  echo "     /usr/local/etc/xray/config.json (default ${c_bld}/novavpn${c_rst})."
  echo "     Check on the VPS:  grep -i path /usr/local/etc/xray/config.json"
  PASS=0
elif [ -z "$RESP" ]; then
  no "No response at all (timeout)."
  echo "   → Port likely filtered by the provider firewall, or Xray isn't running."
  PASS=0
else
  hm "Unexpected response:"
  printf '%s\n' "$RESP" | sed 's/^/     /'
  echo "   → If you see a 101 anywhere above, it's actually working."
fi

# ---- 3) Summary --------------------------------------------------------------
hd "Result"
if [ "$PASS" = "1" ]; then
  ok "${c_bld}Backend looks GOOD.${c_rst} Nova can forward to it."
  echo
  echo "  Next: in a client (Hiddify), import your VLESS link pointed at your NOVA DOMAIN"
  echo "  (not this IP), with path ${c_bld}${WPATH}${c_rst}, then connect and load a webpage."
  echo "  Remember: opening the backend URL in a browser shows ${c_bld}400 — that's normal${c_rst}."
else
  no "${c_bld}Something needs fixing above.${c_rst} Most common: provider firewall on TCP ${PORT}."
  echo
  echo "  On the VPS, confirm Xray is up:"
  echo "    systemctl status xray         # want: active (running)"
  echo "    ss -tlnp | grep ${PORT}          # want: a process LISTENing"
  echo "    grep -i path /usr/local/etc/xray/config.json   # want: ${WPATH}"
fi
echo
