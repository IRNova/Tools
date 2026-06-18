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
#  EASIEST FLOW (the one to share with users): bake the UUID into the command, and the script
#  asks you for your gray-cloud domain during install, then prints ONE finished Backend URL you
#  just paste into the panel — nothing to edit:
#     NOVA_UUID=<your-panel-uuid> bash <(curl -fsSL .../nova-backend.sh)
#  To skip the domain question (fully unattended), also pass NOVA_DOMAIN:
#     NOVA_UUID=<uuid> NOVA_DOMAIN=vps.yourdomain.com bash <(curl -fsSL .../nova-backend.sh)
#  (NOVA_CLIENT_DOMAIN can also be set to fill the client-config example with your panel domain.)
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
# Cloudflare Workers relay (fetch) only to a fixed set of ports.
#   HTTP  ports: 80, 8080, 8880, 2052, 2082, 2086, 2095
#   HTTPS ports: 443, 2053, 2083, 2087, 2096, 8443
# TLS MODE (recommended, NOVA_TLS=1): Xray listens with a self-signed TLS cert on 8443, and the
#   Backend URL becomes https://IP:8443/path. Cloudflare relays WebSockets reliably over https.
# PLAIN MODE (default): Xray listens without TLS on 8080. Simpler, but some Cloudflare setups
#   reject the relayed WS handshake over plain http (403). If you see 403 in /backend-test, use TLS.
NOVA_TLS="${NOVA_TLS:-0}"
if [ "$NOVA_TLS" = "1" ]; then
  NOVA_PORT_VLESS="${NOVA_PORT:-8443}"
  NOVA_PORT_VMESS="${NOVA_PORT_VMESS:-2053}"
  NOVA_SCHEME="https"
else
  NOVA_PORT_VLESS="${NOVA_PORT:-8080}"
  NOVA_PORT_VMESS="${NOVA_PORT_VMESS:-8880}"
  NOVA_SCHEME="http"
fi
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

# ---- detect public IP early (needed for the cert CN and the final URL) -------
PUBIP="$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || curl -fsSL -4 https://ifconfig.me 2>/dev/null || echo 'YOUR_VPS_IP')"

# ---- 3) (TLS mode) generate a self-signed cert ------------------------------
CERT_DIR="/usr/local/etc/xray/cert"
STREAM_SEC='"security": "none"'
if [ "$NOVA_TLS" = "1" ]; then
  say "Generating self-signed TLS certificate (for https relay)..."
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
      -subj "/CN=${PUBIP:-nova-backend}" >/dev/null 2>&1 \
      || { err "Could not generate TLS cert (is openssl installed?). Try: apt-get install -y openssl"; exit 1; }
    chmod 600 "$CERT_DIR/key.pem"
  fi
  ok "TLS certificate ready ($CERT_DIR)"
  # Xray TLS: allowInsecure on the SERVER side isn't needed; Cloudflare's fetch tolerates the
  # self-signed cert because Workers do not verify origin certs the way a browser would.
  STREAM_SEC='"security": "tls", "tlsSettings": { "certificates": [ { "certificateFile": "'"$CERT_DIR"'/cert.pem", "keyFile": "'"$CERT_DIR"'/key.pem" } ] }'
fi

# ---- 4) write the Xray config -----------------------------------------------
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
      "streamSettings": { "network": "ws", ${STREAM_SEC}, "wsSettings": { "path": "${NOVA_PATH}" } }
    },
    {
      "tag": "vmess-ws",
      "port": ${NOVA_PORT_VMESS},
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "${UUID}" } ] },
      "streamSettings": { "network": "ws", ${STREAM_SEC}, "wsSettings": { "path": "${NOVA_PATH}" } }
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

# ---- 8) ask for the gray-cloud domain so we can print ONE ready-to-paste URL --
# The Backend URL must use a domain (Cloudflare Workers can't fetch a bare IP). So we ask for the
# domain here and assemble the FINAL Backend URL the user just pastes into the panel — no editing.
# Non-interactive: pass NOVA_DOMAIN=vps.yourdomain.com on the install command to skip the prompt.
NOVA_DOMAIN="${NOVA_DOMAIN:-}"
if [ -z "$NOVA_DOMAIN" ]; then
  echo
  echo "${c_bld}Almost done — one question so we can give you a ready-to-paste link:${c_rst}"
  echo "  Add a DNS-only (GRAY cloud) A record in Cloudflare pointing a name to this server:"
  echo "      ${c_bld}vps.yourdomain.com${c_rst}  →  ${c_bld}${PUBIP}${c_rst}   (Proxy status: DNS only / gray)"
  echo "  Then type that domain below. (Press Enter to skip and get a template instead.)"
  read -r -p "$(printf '%s' "${c_cyn}Your gray-cloud domain (e.g. vps.yourdomain.com): ${c_rst}")" NOVA_DOMAIN < /dev/tty || NOVA_DOMAIN=""
fi
# strip any scheme / path / trailing dot the user may have pasted
NOVA_DOMAIN="$(printf '%s' "$NOVA_DOMAIN" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#\.$##' | tr -d '[:space:]')"

# ---- 9) print the summary ----------------------------------------------------
NOVA_BACKEND_URL_IP="${NOVA_SCHEME}://${PUBIP}:${NOVA_PORT_VLESS}${NOVA_PATH}"
echo
echo "${c_grn}${c_bld}════════════════════════════════════════════════════════════════${c_rst}"
echo "${c_grn}${c_bld}  ✅ Nova Backend is ready${c_rst}"
echo "${c_grn}${c_bld}════════════════════════════════════════════════════════════════${c_rst}"
echo
if [ -n "$NOVA_DOMAIN" ]; then
  # Friend's flow: one finished link to paste, nothing to edit.
  NOVA_BACKEND_URL="${NOVA_SCHEME}://${NOVA_DOMAIN}:${NOVA_PORT_VLESS}${NOVA_PATH}"
  echo "  ${c_bld}1) Copy this Backend URL and paste it into the panel${c_rst}"
  echo "     (Network & IPs → Backend mode → enable → paste → Save):"
  echo
  echo "       ${c_grn}${c_bld}${NOVA_BACKEND_URL}${c_rst}"
  echo
  echo "  ${c_yel}Make sure ${c_bld}${NOVA_DOMAIN}${c_rst}${c_yel} is set to DNS-only (GRAY cloud) → ${PUBIP} in Cloudflare.${c_rst}"
  echo "  ${c_yel}If it's ORANGE (proxied), switch it to gray, or the Worker can't reach this server.${c_rst}"
else
  # No domain given — keep the old IP + manual-instructions path.
  NOVA_BACKEND_URL="$NOVA_BACKEND_URL_IP"
  echo "  ${c_bld}1) In the Nova panel → Network & IPs → Backend mode:${c_rst}"
  echo "       • Enable backend mode"
  echo "       • Backend URL:  ${c_cyn}${NOVA_BACKEND_URL}${c_rst}"
  echo "       • Save"
  echo
  echo "  ${c_red}${c_bld}⚠ IMPORTANT — do NOT use the raw IP in the Backend URL.${c_rst}"
  echo "    ${c_yel}Cloudflare BLOCKS Workers from fetching bare IPs (SSRF policy) — you'll get a 403.${c_rst}"
  echo "    Instead, in Cloudflare DNS add an A record (e.g. ${c_bld}vps.yourdomain.com${c_rst} → ${PUBIP})"
  echo "    set to ${c_bld}DNS-ONLY (GRAY cloud)${c_rst}, then use that domain in the Backend URL:"
  echo "       ${c_cyn}${NOVA_SCHEME}://vps.yourdomain.com:${NOVA_PORT_VLESS}${NOVA_PATH}${c_rst}"
fi
echo
echo "  ${c_bld}2) Your details (keep them safe):${c_rst}"
echo "       UUID : ${c_cyn}${UUID}${c_rst}"
echo "       Path : ${c_cyn}${NOVA_PATH}${c_rst}"
echo "       VMess port (if you use VMess): ${c_cyn}${NOVA_PORT_VMESS}${c_rst}"
echo
# Client config: fill the real Nova panel domain if we know it, else leave the placeholder.
CLIENT_DOMAIN="${NOVA_CLIENT_DOMAIN:-YOUR-NOVA-DOMAIN}"
echo "  ${c_bld}3) Client config (VLESS) — point it at your ${c_rst}${c_bld}Nova panel domain${c_rst}${c_bld}, not this IP:${c_rst}"
echo "     ${c_cyn}vless://${UUID}@${CLIENT_DOMAIN}:443?security=tls&type=ws&host=${CLIENT_DOMAIN}&sni=${CLIENT_DOMAIN}&path=$(printf '%s' "$NOVA_PATH" | sed 's;/;%2F;g')&encryption=none#Nova-Backend${c_rst}"
echo
echo "  ${c_yel}Flow:${c_rst} client → Cloudflare/Nova (TLS) → this VPS (Xray) → internet"
echo "  ${c_yel}Note:${c_rst} Nova's 'Health check' may say no /health — that's normal; test with a real client."
echo "  ${c_yel}Ports:${c_rst} this uses ${c_bld}${NOVA_PORT_VLESS}${c_rst}/${c_bld}${NOVA_PORT_VMESS}${c_rst} because Cloudflare Workers can only relay to a"
echo "         fixed set of ports (80,8080,8880,2052,2082,2086,2095 for http). Open ${NOVA_PORT_VLESS} in your"
echo "         provider's firewall. Do NOT use 10000 — the Worker can't reach it and clients time out."
echo
echo "${c_grn}  Privacy: nothing was sent off this server. Your IP/UUID/password stay here.${c_rst}"
echo
