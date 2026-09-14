#!/usr/bin/env bash
# Create a VLESS + TCP + REALITY inbound on 3x-ui and print a client import link.
#
# On the VPS:
#   bash <(curl -fsSL https://raw.githubusercontent.com/MiaoMints/3xui-vless-reality/main/create-vless-reality.sh) "node-name"
#   bash create-vless-reality.sh "node-name" --dry-run
set -euo pipefail

NAME=""
DRY_RUN=0
EMAIL=""

usage() {
  echo "Usage: $0 <inbound-name> [--dry-run] [--email <client-email>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --email)
      [[ $# -ge 2 ]] || usage
      EMAIL="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$1"
        shift
      else
        usage
      fi
      ;;
  esac
done

[[ -n "$NAME" ]] || usage
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
INSTALL_ENV="/etc/x-ui/install-result.env"

rand_hex() {
  openssl rand -hex $(( ($1 + 1) / 2 )) | cut -c1-"$1"
}

SHORT_IDS=()
gen_short_ids() {
  local n sid
  SHORT_IDS=()
  for n in 2 4 6 8 10 12 14 16; do
    while true; do
      sid="$(rand_hex "$n")"
      [[ " ${SHORT_IDS[*]} " != *" $sid "* ]] && break
    done
    SHORT_IDS+=("$sid")
  done
}

PRIV=""
PUB=""
gen_keys() {
  local out
  [[ -x "$XRAY_BIN" ]] || { echo "missing $XRAY_BIN" >&2; exit 1; }
  out="$("$XRAY_BIN" x25519)"
  PRIV="$(printf '%s\n' "$out" | awk -F': ' '/^PrivateKey:/{print $2}')"
  PUB="$(printf '%s\n' "$out" | awk -F': ' '/PublicKey:|^Password/{print $2; exit}')"
  [[ -n "$PRIV" && -n "$PUB" ]] || { echo "failed to generate REALITY keys" >&2; exit 1; }
}

gen_uuid() {
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

TOKEN=""
BASE=""
HOST=""
load_panel() {
  local port path access show
  TOKEN="${XUI_TOKEN:-}"
  BASE="${XUI_BASE:-}"
  HOST="${XUI_PUBLIC_HOST:-}"

  if [[ -f "$INSTALL_ENV" ]]; then
    TOKEN="${TOKEN:-$(awk -F= '/^XUI_API_TOKEN=/{print substr($0,15)}' "$INSTALL_ENV")}"
    port="$(awk -F= '/^XUI_PANEL_PORT=/{print $2}' "$INSTALL_ENV")"
    path="$(awk -F= '/^XUI_WEB_BASE_PATH=/{print $2}' "$INSTALL_ENV")"
    access="$(awk -F= '/^XUI_ACCESS_URL=/{print $2}' "$INSTALL_ENV")"
    path="${path#/}"
    path="${path%/}"
    port="${port:-2053}"
    if [[ -z "$BASE" ]]; then
      BASE="https://127.0.0.1:${port}/${path}"
    fi
    if [[ -z "$HOST" && "$access" == *://* ]]; then
      HOST="${access#*://}"
      HOST="${HOST%%[:/]*}"
    fi
  fi

  if [[ -z "$TOKEN" ]] && command -v x-ui >/dev/null 2>&1; then
    TOKEN="$(x-ui setting -getApiToken 2>/dev/null | awk -F': ' '/apiToken/{print $2}')"
  fi
  if [[ -z "$BASE" ]] && command -v x-ui >/dev/null 2>&1; then
    show="$(x-ui setting -show true 2>/dev/null || true)"
    port="$(printf '%s\n' "$show" | awk -F': ' '/^port:/{print $2; exit}')"
    path="$(printf '%s\n' "$show" | awk -F': ' '/webBasePath:/{print $2; exit}')"
    path="${path#/}"
    path="${path%/}"
    port="${port:-2053}"
    BASE="http://127.0.0.1:${port}/${path}"
  fi
  if [[ -z "$HOST" ]]; then
    HOST="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$HOST" ]]; then
    HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  HOST="${HOST:-127.0.0.1}"
  BASE="${BASE%/}"
  if [[ -z "$TOKEN" || -z "$BASE" ]]; then
    echo "missing panel API. Run on the VPS or set XUI_BASE and XUI_TOKEN." >&2
    exit 1
  fi
}

api_json() {
  local method="$1" path="$2" data="${3:-}"
  local tmp http
  tmp="$(mktemp)"
  if [[ -n "$data" ]]; then
    http="$(curl -sS -k --max-time 60 -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "$data" "$BASE$path")"
  else
    http="$(curl -sS -k --max-time 60 -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" "$BASE$path")"
  fi
  if [[ "$http" != 2* ]]; then
    echo "API $method $path failed: $http $(cat "$tmp")" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

try_bases() {
  local orig="$BASE" cand
  for cand in "$orig" "${orig/https:/http:}" "${orig/http:/https:}"; do
    BASE="$cand"
    if curl -sS -k --max-time 8 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" "$BASE/panel/api/inbounds/list" | grep -q '^2'; then
      return 0
    fi
  done
  BASE="$orig"
}

build_payload() {
  NAME="$NAME" PORT="$PORT" PRIV="$PRIV" PUB="$PUB" SPIDER="$SPIDER" SHORT_IDS="${SHORT_IDS[*]}" python3 - <<'PY'
import json, os
sids = os.environ["SHORT_IDS"].split()
snis = [
    "www.amazon.com", "amazon.com", "amzn.com", "www.amzn.com", "www.m.amazon.com",
    "us.amazon.com", "home.amazon.com", "origin-www.amazon.com", "buybox.amazon.com",
    "uedata.amazon.com", "yellowpages.amazon.com", "yp.amazon.com", "iphone.amazon.com",
    "mp3recs.amazon.com", "huddles.amazon.com", "corporate.amazon.com",
    "shop.business.amazon.com", "www.cdn.amazon.com", "test-www.amazon.com",
    "konrad-test.amazon.com", "p-yo-www-amazon-com-kalias.amazon.com",
    "p-nt-www-amazon-com-kalias.amazon.com", "p-y3-www-amazon-com-kalias.amazon.com",
    "buckeye-retail-website.amazon.com",
]
print(json.dumps({
    "enable": True,
    "remark": os.environ["NAME"],
    "listen": "",
    "port": int(os.environ["PORT"]),
    "protocol": "vless",
    "expiryTime": 0,
    "total": 0,
    "disableFlow": False,
    "trafficReset": "never",
    "shareAddrStrategy": "listen",
    "settings": {
        "clients": [],
        "decryption": "none",
        "encryption": "none",
        "testseed": [900, 500, 900, 256],
        "fallbacks": [],
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "externalProxy": [],
        "realitySettings": {
            "show": False,
            "xver": 0,
            "target": "www.amazon.com:443",
            "serverNames": snis,
            "privateKey": os.environ["PRIV"],
            "minClientVer": "1.0.0",
            "maxClientVer": "",
            "maxTimediff": 0,
            "shortIds": sids,
            "mldsa65Seed": "",
            "limitFallbackUpload": {"afterBytes": 0, "bytesPerSec": 0, "burstBytesPerSec": 0},
            "limitFallbackDownload": {"afterBytes": 0, "bytesPerSec": 0, "burstBytesPerSec": 0},
            "settings": {
                "publicKey": os.environ["PUB"],
                "fingerprint": "chrome",
                "serverName": "",
                "spiderX": os.environ["SPIDER"],
                "mldsa65Verify": "",
            },
        },
        "tcpSettings": {
            "acceptProxyProtocol": False,
            "header": {"type": "none"},
        },
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
}, ensure_ascii=False))
PY
}

make_link() {
  CLIENT_UUID="$CLIENT_UUID" HOST="$HOST" PORT="$PORT" PUB="$PUB" SNI="$SNI" SID="$SID" SPIDER="$SPIDER" NAME="$NAME" python3 - <<'PY'
from urllib.parse import quote, urlencode
import os
q = urlencode({
    "encryption": "none",
    "type": "tcp",
    "security": "reality",
    "pbk": os.environ["PUB"],
    "fp": "chrome",
    "sni": os.environ["SNI"],
    "sid": os.environ["SID"],
    "spx": os.environ["SPIDER"],
})
print("vless://%s@%s:%s?%s#%s" % (
    os.environ["CLIENT_UUID"], os.environ["HOST"], os.environ["PORT"], q, quote(os.environ["NAME"])
))
PY
}

gen_keys
CLIENT_UUID="$(gen_uuid)"
gen_short_ids
SID="${SHORT_IDS[RANDOM % ${#SHORT_IDS[@]}]}"
SNI="www.amazon.com"
SPIDER="/$(rand_hex 15)"
EMAIL="${EMAIL:-u$(rand_hex 8)}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  PORT="$((20000 + RANDOM % 39999))"
  HOST="${XUI_PUBLIC_HOST:-YOUR_IP}"
  INBOUND_JSON="$(build_payload)"
  printf '%s' "$INBOUND_JSON" | CLIENT_UUID="$CLIENT_UUID" EMAIL="$EMAIL" python3 -c '
import json, os, sys
p = json.load(sys.stdin)
p["settings"]["clients"] = [{
    "id": os.environ["CLIENT_UUID"],
    "email": os.environ["EMAIL"],
    "flow": "",
    "enable": True,
    "tgId": 0,
}]
print(json.dumps(p, ensure_ascii=False, indent=2))
'
  echo
  make_link
  exit 0
fi

load_panel
try_bases
PORTS_JSON="$(api_json GET /panel/api/inbounds/list | python3 -c 'import json,sys; print(json.dumps([x.get("port") for x in (json.load(sys.stdin).get("obj") or []) if x.get("port")]))')"
PORT="$(PORTS_JSON="$PORTS_JSON" python3 - <<'PY'
import json, os, random, sys
taken = set(json.loads(os.environ["PORTS_JSON"]) or [])
reserved = taken | {22, 80, 443, 2096, 60000, 62789}
for _ in range(200):
    port = random.randint(20000, 59999)
    if port not in reserved:
        print(port)
        raise SystemExit
sys.exit("no free port")
PY
)"

INBOUND_JSON="$(build_payload)"
CREATED="$(api_json POST /panel/api/inbounds/add "$INBOUND_JSON")"
IID="$(printf '%s' "$CREATED" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("obj",{}).get("id") or ""); raise SystemExit(0 if d.get("success") else "create inbound failed: "+(d.get("msg") or ""))')"
CLIENT_JSON="$(CLIENT_UUID="$CLIENT_UUID" EMAIL="$EMAIL" NAME="$NAME" IID="$IID" python3 - <<'PY'
import json, os
print(json.dumps({
    "client": {
        "email": os.environ["EMAIL"],
        "id": os.environ["CLIENT_UUID"],
        "flow": "",
        "tgId": 0,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "comment": os.environ["NAME"],
    },
    "inboundIds": [int(os.environ["IID"])],
}, ensure_ascii=False))
PY
)"
ADDED="$(api_json POST /panel/api/clients/add "$CLIENT_JSON")"
printf '%s' "$ADDED" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("success") else "create client failed: "+(d.get("msg") or ""))'

echo "inbound_id=$IID"
echo "port=$PORT"
echo "email=$EMAIL"
echo "uuid=$CLIENT_UUID"
echo "public_key=$PUB"
echo "short_id=$SID"
echo "sni=$SNI"
make_link
