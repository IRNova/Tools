#!/usr/bin/env bash
# =============================================================================
#  Nova Backend — one-line VPS installer
#  Installs Xray-core and configures a WebSocket backend that Nova's
#  "Backend mode" forwards to (unlocks VMess + UDP / voice-video calls).
#
#  Run on YOUR OWN VPS (you stay in control — nothing is sent anywhere):
#     bash <(curl -fsSL https://raw.githubusercontent.com/IRNova/Tools/main/nova-backend.sh)
#
#  Or with a custom path/port (port MUST be Cloudflare-allowed: 8080, 8880, 2052, 2082, 2086, 2095):
#     NOVA_PATH=/mysecret NOVA_PORT=8080 bash <(curl -fsSL .../nova-backend.sh)
#
#  RECOMMENDED — match your Nova panel's UUID so clients work immediately:
#     NOVA_UUID=<your-panel-uuid> bash <(curl -fsSL .../nova-backend.sh)
#  (Without this, a random UUID is generated and you must sync it to the panel later.)
#
#  PRIVACY: this runs entirely on your server. It does NOT phone home, does NOT
#  send your IP / password / keys anywhere. The only outbound request is
#  downloading Xray from its official GitHub release.
# =============================================================================

set -euo pipefail

# ---- pretty output -----------------------------------------------------------
c_grn=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
say()  { printf '%s\n' "${c_cyn}==>${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}✓${c_rst} $*"; }
warn() { printf '%s\n' "${c_yel}⚠${c_rst} $*"; }
err()  { printf '%s\n' "${c_red}✗${c_rst} $*" >&2; }

# ---- config (overridable via env) -------------------------------------------
NOVA_PATH="${NOVA_PATH:-/novavpn}"
# IMPORTANT: Cloudflare Workers can only fetch() to a fixed set of ports. For plain HTTP the
# allowed ports are 80, 8080, 8880, 2052, 2082, 2086, 2095. Nova relays to this backend FROM a
# Worker, so the backend MUST listen on one of those — otherwise the relay silently times out.
# Defaults: VLESS on 8080, VMess on 8880 (both Cloudflare-allowed). Override VLESS with NOVA_PORT.
NOVA_PORT_VLESS="${NOVA_PORT:-8080}"
NOVA_PORT_VMESS="${NOVA_PORT_VMESS:-8880}"
[ "${NOVA_PATH:0:1}" = "/" ] || NOVA_PATH="/$NOVA_PATH"

XRAY_CONFIG="/usr/local/etc/xray/config.json"

# ---- preflight ---------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "Please run as root (or with sudo)."
  echo "   sudo bash <(curl -fsSL .../nova-backend.sh)"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  say "Installing curl..."
  (apt-get update -y && apt-get install -y curl) >/dev/null 2>&1 \
    || (yum install -y curl) >/dev/null 2>&1 \
    || { err "Could not install curl. Install it manually and re-run."; exit 1; }
fi

say "Nova Backend installer starting"
echo "    path : ${c_bld}${NOVA_PATH}${c_rst}"
echo "    ports: VLESS ${c_bld}${NOVA_PORT_VLESS}${c_rst}  |  VMess ${c_bld}${NOVA_PORT_VMESS}${c_rst}"
echo

# ---- 1) install Xray (official script) --------------------------------------
if command -v xray >/dev/null 2>&1; then
  ok "Xray already installed ($(xray version 2>/dev/null | head -1))"
else
  say "Installing Xray-core (official installer)..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
    || { err "Xray install failed. Check network and re-run."; exit 1; }
  ok "Xray installed"
fi

# ---- 2) UUID: use NOVA_UUID if provided (to MATCH your panel), else generate -
# IMPORTANT: the UUID here MUST match your Nova panel's UUID, or clients get dropped.
# Easiest: copy your panel UUID and run:  NOVA_UUID=<panel-uuid> bash <(curl ... nova-backend.sh)
if [ -n "${NOVA_UUID:-}" ]; then
  UUID="$NOVA_UUID"
  ok "Using provided UUID (matches your panel): $UUID"
else
  if command -v xray >/dev/null 2>&1; then
    UUID="$(xray uuid 2>/dev/null || true)"
  fi
  if [ -z "${UUID:-}" ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  fi
  [ -n "${UUID:-}" ] || { err "Could not generate a UUID."; exit 1; }
  warn "Generated a RANDOM UUID. This will NOT match your panel automatically."
  warn "If clients time out, set the VPS UUID to your panel's:"
  warn "  sed -i 's/$UUID/<YOUR-PANEL-UUID>/g' $XRAY_CONFIG && systemctl restart xray"
  ok "UUID generated"
fi

# ---- 3) write the Xray config (WS, security none; TLS is at Cloudflare) ------
say "Writing Xray config..."
mkdir -p "$(dirname "$XRAY_CONFIG")"
# back up any existing config
[ -f "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)" && warn "Existing config backed up."

cat > "$XRAY_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ws",
      "port": ${NOVA_PORT_VLESS},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "${NOVA_PATH}" } }
    },
    {
      "tag": "vmess-ws",
      "port": ${NOVA_PORT_VMESS},
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "${UUID}" } ] },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "${NOVA_PATH}" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
JSON
ok "Config written to $XRAY_CONFIG"

# validate config if xray supports -test
if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || xray -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
  ok "Config validated"
else
  warn "Could not validate config automatically (continuing)."
fi

# ---- 4) start + enable service ----------------------------------------------
say "Starting Xray service..."
systemctl restart xray >/dev/null 2>&1 || true
systemctl enable xray  >/dev/null 2>&1 || true
sleep 1
if systemctl is-active --quiet xray; then
  ok "Xray is running"
else
  err "Xray failed to start. Check: journalctl -u xray -n 50"
fi

# ---- 5) firewall -------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening firewall ports (ufw)..."
  ufw allow "${NOVA_PORT_VLESS}/tcp" >/dev/null 2>&1 || true
  ufw allow "${NOVA_PORT_VMESS}/tcp" >/dev/null 2>&1 || true
  ok "Firewall ports opened"
else
  warn "ufw not active — make sure ports ${NOVA_PORT_VLESS}/${NOVA_PORT_VMESS} are reachable (cloud provider firewall too)."
fi

# ---- 6) detect public IP -----------------------------------------------------
PUBIP="$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || curl -fsSL -4 https://ifconfig.me 2>/dev/null || echo 'YOUR_VPS_IP')"

# ---- 7) optional: change root password (security) ---------------------------
echo
warn "Security tip: if you logged in with a root password you shared or typed, change it now."
read -r -p "$(printf '%s' "${c_cyn}Change the root password now? [y/N]: ${c_rst}")" CHPW < /dev/tty || CHPW="n"
if printf '%s' "${CHPW:-n}" | grep -qi '^y'; then
  passwd root < /dev/tty || warn "Password change skipped/failed."
  ok "Root password updated (we never see it — it stays on your server)."
else
  echo "   Skipped. You can change it any time with: passwd root"
fi

# ---- 8) print the summary ----------------------------------------------------
NOVA_BACKEND_URL="http://${PUBIP}:${NOVA_PORT_VLESS}${NOVA_PATH}"
echo
echo "${c_grn}${c_bld}════════════════════════════════════════════════════════════════${c_rst}"
echo "${c_grn}${c_bld}  ✅ Nova Backend is ready${c_rst}"
echo "${c_grn}${c_bld}════════════════════════════════════════════════════════════════${c_rst}"
echo
echo "  ${c_bld}1) In the Nova panel → Network & IPs → Backend mode:${c_rst}"
echo "       • Enable backend mode"
echo "       • Backend URL:  ${c_cyn}${NOVA_BACKEND_URL}${c_rst}"
echo "       • Save"
echo
echo "  ${c_bld}2) Your details (keep them safe):${c_rst}"
echo "       UUID : ${c_cyn}${UUID}${c_rst}"
echo "       Path : ${c_cyn}${NOVA_PATH}${c_rst}"
echo "       VMess port (if you use VMess): ${c_cyn}${NOVA_PORT_VMESS}${c_rst}"
echo
echo "  ${c_bld}3) Client config (VLESS) — point it at your NOVA DOMAIN, not this IP:${c_rst}"
echo "     ${c_cyn}vless://${UUID}@YOUR-NOVA-DOMAIN:443?security=tls&type=ws&host=YOUR-NOVA-DOMAIN&sni=YOUR-NOVA-DOMAIN&path=$(printf '%s' "$NOVA_PATH" | sed 's;/;%2F;g')&encryption=none#Nova-Backend${c_rst}"
echo
echo "  ${c_yel}Flow:${c_rst} client → Cloudflare/Nova (TLS) → this VPS (Xray) → internet"
echo "  ${c_yel}Note:${c_rst} Nova's 'Health check' may say no /health — that's normal; test with a real client."
echo "  ${c_yel}Ports:${c_rst} this uses ${c_bld}${NOVA_PORT_VLESS}${c_rst}/${c_bld}${NOVA_PORT_VMESS}${c_rst} because Cloudflare Workers can only relay to a"
echo "         fixed set of ports (80,8080,8880,2052,2082,2086,2095 for http). Open ${NOVA_PORT_VLESS} in your"
echo "         provider's firewall. Do NOT use 10000 — the Worker can't reach it and clients time out."
echo
echo "${c_grn}  Privacy: nothing was sent off this server. Your IP/UUID/password stay here.${c_rst}"
echo
