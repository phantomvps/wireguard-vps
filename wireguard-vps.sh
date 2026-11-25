#!/usr/bin/env bash
# wireguard-vps.sh - your own WireGuard VPN server on an Ubuntu / Debian VPS, with ready client configs.
#
# What it does:
#   1. Installs WireGuard (plus qrencode with --qr).
#   2. Creates the server keys and /etc/wireguard/wg0.conf ONCE: existing keys are never overwritten.
#   3. Creates client configs (client1..clientN) in /etc/wireguard/clients/.
#   4. Turns on IPv4 forwarding and NAT through the default network interface.
#   5. Opens the UDP port in ufw if ufw is active, and starts wg-quick@wg0 (also at boot).
#
# Usage:  sudo bash wireguard-vps.sh [--clients 3] [--port 51820] [--endpoint HOST] [--subnet 10.8.0.0/24]
#                                    [--dns 1.1.1.1,9.9.9.9] [--wan-if eth0] [--qr] [--no-start] [--yes]
#         sudo bash wireguard-vps.sh --add-client NAME [--qr]     add a client later
#         sudo bash wireguard-vps.sh --remove-client NAME         remove a client (its key stops working)
#         sudo bash wireguard-vps.sh --show-client NAME [--qr]    print a client config again
#         sudo bash wireguard-vps.sh --list-clients
# --no-start writes everything but does not bring wg0 up (for containers without the WireGuard kernel module).
# Tested on Ubuntu 22.04 and 24.04 (see .github/workflows/test.yml); written for Debian 12 / 13 too.
# License: MIT. Maintained by the PhantomVPS team - https://phantomvps.com
set -euo pipefail

WG_DIR=/etc/wireguard; IFACE=wg0
CONF="$WG_DIR/$IFACE.conf"; ENVF="$WG_DIR/wireguard-vps.env"; CDIR="$WG_DIR/clients"
CLIENTS=3; PORT=51820; ENDPOINT=""; SUBNET="10.8.0.0/24"; DNS="1.1.1.1,9.9.9.9"; WAN_IF=""
QR=0; NO_START=0; ASSUME_YES=0; ACTION=setup; CNAME=""; GIVEN=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }
need_arg() { [ -n "${2:-}" ] || die "$1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --clients)  need_arg "$@"; CLIENTS="$2"; GIVEN="$GIVEN clients"; shift 2 ;;
    --port)     need_arg "$@"; PORT="$2"; GIVEN="$GIVEN port"; shift 2 ;;
    --endpoint) need_arg "$@"; ENDPOINT="$2"; GIVEN="$GIVEN endpoint"; shift 2 ;;
    --subnet)   need_arg "$@"; SUBNET="$2"; GIVEN="$GIVEN subnet"; shift 2 ;;
    --dns)      need_arg "$@"; DNS="$2"; GIVEN="$GIVEN dns"; shift 2 ;;
    --wan-if)   need_arg "$@"; WAN_IF="$2"; GIVEN="$GIVEN wan-if"; shift 2 ;;
    --add-client)    need_arg "$@"; ACTION=add; CNAME="$2"; shift 2 ;;
    --remove-client) need_arg "$@"; ACTION=remove; CNAME="$2"; shift 2 ;;
    --show-client)   need_arg "$@"; ACTION=show; CNAME="$2"; shift 2 ;;
    --list-clients)  ACTION=list; shift ;;
    --qr) QR=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---- input validation (before anything is changed) ----
valid_octet() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -le 255 ]; }
[[ "$CLIENTS" =~ ^[0-9]+$ ]] && [ "$CLIENTS" -ge 0 ] && [ "$CLIENTS" -le 250 ] || die "bad --clients (0-250): $CLIENTS"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "bad --port: $PORT"
[[ "$SUBNET" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]] || die "bad --subnet (use a /24 like 10.8.0.0/24): $SUBNET"
o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"; o3="${BASH_REMATCH[3]}"
valid_octet "$o1" && valid_octet "$o2" && valid_octet "$o3" || die "bad --subnet: $SUBNET"
[ -z "$ENDPOINT" ] || [[ "$ENDPOINT" =~ ^[A-Za-z0-9.:-]{1,253}$ ]] || die "bad --endpoint (hostname or IP): $ENDPOINT"
[[ "$DNS" =~ ^[0-9A-Fa-f.:]+(,[0-9A-Fa-f.:]+)*$ ]] || die "bad --dns (comma-separated IPs): $DNS"
[ -z "$WAN_IF" ] || [[ "$WAN_IF" =~ ^[A-Za-z0-9._@-]{1,15}$ ]] || die "bad --wan-if: $WAN_IF"
[ -z "$CNAME" ] || [[ "$CNAME" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "bad client name (letters, digits, - and _, max 32): $CNAME"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash $0)"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
OS_ID="$(. /etc/os-release && echo "${ID:-}")"   # read in a subshell: os-release sets NAME, VERSION, ...
case "$OS_ID" in ubuntu|debian) ;; *) die "only Ubuntu and Debian are supported (found: ${OS_ID:-unknown})" ;; esac

# ---- helpers ----
load_env() {   # parse KEY=VALUE lines (never sourced), then re-validate
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PORT) S_PORT="$v" ;; SUBNET) S_SUBNET="$v" ;; ENDPOINT) S_ENDPOINT="$v" ;;
      DNS) S_DNS="$v" ;; WAN_IF) S_WAN_IF="$v" ;;
    esac
  done < "$ENVF"
  [[ "${S_PORT:-}" =~ ^[0-9]+$ ]] && [[ "${S_SUBNET:-}" =~ ^[0-9.]+/24$ ]] && [[ "${S_ENDPOINT:-}" =~ ^[A-Za-z0-9.:-]+$ ]] \
    && [[ "${S_DNS:-}" =~ ^[0-9A-Fa-f.:,]+$ ]] && [[ "${S_WAN_IF:-}" =~ ^[A-Za-z0-9._@-]+$ ]] || die "$ENVF is damaged; fix it by hand"
}
prefix_of() { echo "${1%.0/24}"; }
is_up() { ip link show "$IFACE" >/dev/null 2>&1; }
live_sync() {   # apply peer changes to a running wg0 without dropping other clients
  if is_up; then wg syncconf "$IFACE" <(wg-quick strip "$IFACE"); info "Applied to running $IFACE"; fi
}
next_ip() {
  local p n; p="$(prefix_of "$S_SUBNET")"
  for n in $(seq 2 254); do
    grep -qE "^AllowedIPs = ${p//./\\.}\.$n/32\$" "$CONF" || { echo "$p.$n"; return 0; }
  done
  die "no free addresses left in $S_SUBNET"
}
endpoint_fmt() { case "$1" in *:*) echo "[$1]" ;; *) echo "$1" ;; esac; }   # IPv6 needs brackets
show_client() {
  local f="$CDIR/$1.conf"
  [ -f "$f" ] || die "no client named $1 (see --list-clients)"
  echo; echo "----- client: $1 ($f) -----"; cat "$f"
  if [ "$QR" -eq 1 ]; then
    command -v qrencode >/dev/null 2>&1 || apt-get -y -q install qrencode >/dev/null
    qrencode -t ansiutf8 < "$f"
  fi
}
add_client() {
  local name="$1" ip priv pub psk spub
  if [ -f "$CDIR/$name.conf" ] || grep -qx "# client: $name" "$CONF"; then
    info "Client $name already exists (kept)"; return 0
  fi
  ip="$(next_ip)"; priv="$(wg genkey)"; pub="$(printf '%s' "$priv" | wg pubkey)"; psk="$(wg genpsk)"
  spub="$(cat "$WG_DIR/server.pub")"
  printf '\n[Peer]\n# client: %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$psk" "$ip" >> "$CONF"
  printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n' \
    "$priv" "$ip" "${S_DNS//,/, }" "$spub" "$psk" "$(endpoint_fmt "$S_ENDPOINT")" "$S_PORT" > "$CDIR/$name.conf"
  info "Added client $name ($ip)"
}
remove_client() {
  local name="$1" tmp
  grep -qx "# client: $name" "$CONF" || [ -f "$CDIR/$name.conf" ] || die "no client named $name"
  tmp="$(mktemp "$WG_DIR/.wg0.XXXXXX")"
  awk -v tag="# client: $name" '
    function flush() { if (buf != "" && index(buf, "\n" tag "\n") == 0) printf "%s", buf; buf = "" }
    /^\[/ { flush() }
    { buf = buf $0 "\n" }
    END { flush() }' "$CONF" > "$tmp"
  grep -q '^\[Interface\]' "$tmp" || { rm -f "$tmp"; die "refusing to write a config without [Interface]"; }
  chmod 600 "$tmp"; mv "$tmp" "$CONF"
  rm -f "$CDIR/$name.conf"
  info "Removed client $name"
}
require_setup() { [ -f "$CONF" ] && [ -f "$ENVF" ] || die "no setup found: run 'sudo bash $0' first"; load_env; }

umask 077
export DEBIAN_FRONTEND=noninteractive

# ---- client management actions ----
case "$ACTION" in
  list)   require_setup; grep -E '^# client: ' "$CONF" | sed 's/^# client: //' || echo "(no clients)"; exit 0 ;;
  show)   require_setup; show_client "$CNAME"; exit 0 ;;
  add)    require_setup; add_client "$CNAME"; live_sync; show_client "$CNAME"; exit 0 ;;
  remove) require_setup; remove_client "$CNAME"; live_sync; exit 0 ;;
esac

# ---- setup ----
if [ -f "$ENVF" ]; then
  load_env
  for g in $GIVEN; do
    case "$g" in clients) ;; *) warn "existing setup found: --$g is ignored (settings are in $ENVF)" ;; esac
  done
else
  if [ -z "$WAN_IF" ]; then
    WAN_IF="$( { ip -4 route show default 2>/dev/null || true; } | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    [ -n "$WAN_IF" ] || die "cannot detect the default network interface; pass --wan-if"
  fi
  ip link show "$WAN_IF" >/dev/null 2>&1 || die "network interface not found: $WAN_IF"
  if [ -z "$ENDPOINT" ]; then
    ENDPOINT="$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    [ -n "$ENDPOINT" ] || die "cannot detect this server's IP; pass --endpoint"
    case "$ENDPOINT" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
        warn "detected IP $ENDPOINT is private: clients cannot reach it from the internet. Pass --endpoint PUBLIC_IP_OR_HOSTNAME." ;;
    esac
  fi
  S_PORT="$PORT"; S_SUBNET="$SUBNET"; S_ENDPOINT="$ENDPOINT"; S_DNS="$DNS"; S_WAN_IF="$WAN_IF"
fi

echo "Plan: WireGuard on UDP $S_PORT, subnet $S_SUBNET, endpoint $S_ENDPOINT, NAT via $S_WAN_IF, client DNS $S_DNS,"
echo "      clients on first setup: $CLIENTS, start now: $((1-NO_START))"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Continue? [y/N] " a; case "$a" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

info "Installing WireGuard"
apt-get update -q
pkgs=(wireguard-tools iptables); [ "$QR" -eq 1 ] && pkgs+=(qrencode)
apt-get -y -q install "${pkgs[@]}"

if [ "$NO_START" -eq 0 ]; then
  modprobe wireguard 2>/dev/null || [ -d /sys/module/wireguard ] \
    || die "this kernel has no WireGuard support (common on container VPS). Re-run with --no-start to only create the configs."
fi

info "IPv4 forwarding"
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-wireguard-vps.conf
chmod 644 /etc/sysctl.d/99-wireguard-vps.conf
sysctl -q -w net.ipv4.ip_forward=1 || warn "could not set net.ipv4.ip_forward now (it is set for the next boot)"

install -d -m 700 "$WG_DIR" "$CDIR"
if [ -s "$WG_DIR/server.key" ]; then
  info "Server key exists (kept)"
else
  info "Creating server keys"
  wg genkey > "$WG_DIR/server.key"
fi
wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub"

if [ -f "$CONF" ]; then
  info "$CONF exists (kept)"
else
  info "Writing $CONF"
  p="$(prefix_of "$S_SUBNET")"
  cat > "$CONF" <<EOF
# Managed by wireguard-vps.sh - add/remove clients with --add-client / --remove-client
[Interface]
Address = $p.1/24
ListenPort = $S_PORT
PrivateKey = $(cat "$WG_DIR/server.key")
PostUp = iptables -t nat -A POSTROUTING -s $S_SUBNET -o $S_WAN_IF -j MASQUERADE
PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT
PostUp = iptables -I FORWARD 1 -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $S_SUBNET -o $S_WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF
fi
if [ ! -f "$ENVF" ]; then
  printf 'PORT=%s\nSUBNET=%s\nENDPOINT=%s\nDNS=%s\nWAN_IF=%s\n' "$S_PORT" "$S_SUBNET" "$S_ENDPOINT" "$S_DNS" "$S_WAN_IF" > "$ENVF"
fi

NEW_CLIENTS=()
if grep -q '^\[Peer\]' "$CONF"; then
  info "Clients already exist (kept). Use --add-client NAME for more."
else
  for i in $(seq 1 "$CLIENTS"); do add_client "client$i"; NEW_CLIENTS+=("client$i"); done
fi

if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then   # no -q: avoids SIGPIPE + pipefail
  info "ufw is active: allowing $S_PORT/udp"
  ufw allow "$S_PORT/udp" comment 'wireguard-vps'
fi

if [ "$NO_START" -eq 0 ]; then
  systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1
  if systemctl is-active --quiet "wg-quick@$IFACE"; then
    live_sync
  else
    info "Starting $IFACE"
    systemctl start "wg-quick@$IFACE"
  fi
  wg show "$IFACE" | awk 'NR <= 5'
else
  info "--no-start: configs are written, $IFACE was not started"
fi

for c in "${NEW_CLIENTS[@]}"; do show_client "$c"; done
echo
info "Done. Import a client file into the WireGuard app (or scan the QR code with --show-client NAME --qr)."
info "Client files: $CDIR/   Add more: sudo bash $0 --add-client phone"
