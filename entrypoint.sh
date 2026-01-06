#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Persisted paths (bind mounts)
# ----------------------------
: "${DATA_DIR:=/data}"
: "${BLOCKCHAIN_DIR:=/blockchain}"

# ----------------------------
# Monerod ports / binding
# ----------------------------
: "${RPC_BIND_IP:=0.0.0.0}"
: "${RPC_PORT:=18081}"
: "${P2P_BIND_IP:=0.0.0.0}"
: "${P2P_PORT:=18080}"

# ----------------------------
# Monerod behavior
# ----------------------------
: "${PRUNE_BLOCKCHAIN:=1}"
: "${LOG_LEVEL:=0}"
: "${RPC_LOGIN:=}"   # "user:pass" (digest auth). Strongly recommended if exposed.
: "${RESTRICTED_RPC:=1}"

# ----------------------------
# Tor proxy (via separate container)
# ----------------------------
: "${TOR_SOCKS_HOST:=tor}"
: "${TOR_SOCKS_PORT:=9050}"

# If you set this, monerod will refuse to start unless it can reach Tor SOCKS
: "${TOR_REQUIRED:=1}"
: "${TOR_WAIT_SECONDS:=60}"

# Optional: enforce that monero user can only egress to Tor SOCKS (needs NET_ADMIN)
: "${ENFORCE_TOR_EGRESS:=0}"

# ----------------------------
# Setup filesystem
# ----------------------------
mkdir -p "${DATA_DIR}" "${BLOCKCHAIN_DIR}"
chown -R monero:monero "${DATA_DIR}" "${BLOCKCHAIN_DIR}"

# Ensure blockchain LMDB lives under /blockchain/lmdb
mkdir -p "${BLOCKCHAIN_DIR}/lmdb"

# If /data/lmdb exists and is not a symlink, refuse (prevents chain being written to the wrong disk)
if [[ -e "${DATA_DIR}/lmdb" && ! -L "${DATA_DIR}/lmdb" ]]; then
  echo "ERROR: ${DATA_DIR}/lmdb exists and is NOT a symlink."
  echo "Refusing to start to avoid writing blockchain into ${DATA_DIR}."
  echo "Fix:"
  echo "  mv ${DATA_DIR}/lmdb ${DATA_DIR}/lmdb.bak.$(date +%s)"
  exit 1
fi

# Create/refresh symlink
ln -sfn "${BLOCKCHAIN_DIR}/lmdb" "${DATA_DIR}/lmdb"

echo "[init] DATA_DIR=${DATA_DIR}"
echo "[init] BLOCKCHAIN_DIR=${BLOCKCHAIN_DIR}"
echo "[init] lmdb -> $(readlink -f "${DATA_DIR}/lmdb" || true)"

# ----------------------------
# Wait for Tor SOCKS (optional but recommended)
# ----------------------------
echo "[init] Tor SOCKS target: ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}"
if [[ "${TOR_REQUIRED}" == "1" ]]; then
  echo "[init] waiting up to ${TOR_WAIT_SECONDS}s for Tor SOCKS..."
  SECS=0
  until nc -z "${TOR_SOCKS_HOST}" "${TOR_SOCKS_PORT}" >/dev/null 2>&1; do
    sleep 1
    SECS=$((SECS+1))
    if (( SECS >= TOR_WAIT_SECONDS )); then
      echo "ERROR: Tor SOCKS ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT} not reachable after ${TOR_WAIT_SECONDS}s."
      echo "Tip: ensure the tor container is on the same Docker network and SOCKS is enabled."
      exit 1
    fi
  done
  echo "[init] Tor SOCKS reachable."
else
  echo "[init] TOR_REQUIRED=0 (will start even if Tor is down)."
fi

# Resolve Tor host to an IP *before* optional iptables rules (avoids DNS after lockdown)
TOR_IP="$(getent hosts "${TOR_SOCKS_HOST}" | awk '{print $1; exit}' || true)"
if [[ -n "${TOR_IP}" ]]; then
  echo "[init] Tor resolved: ${TOR_SOCKS_HOST} -> ${TOR_IP}"
else
  echo "[init] Tor resolve: ${TOR_SOCKS_HOST} -> (unresolved now; continuing)"
fi

# ----------------------------
# Optional egress enforcement
# ----------------------------
if [[ "${ENFORCE_TOR_EGRESS}" == "1" ]]; then
  if [[ -z "${TOR_IP}" ]]; then
    echo "ERROR: ENFORCE_TOR_EGRESS=1 but failed to resolve TOR_SOCKS_HOST=${TOR_SOCKS_HOST}."
    echo "Fix: ensure Tor container is reachable on the network before enabling enforcement."
    exit 1
  fi

  echo "[fw] enforcing egress: monero user may only connect to Tor SOCKS ${TOR_IP}:${TOR_SOCKS_PORT}"
  MONERO_UID="$(id -u monero)"

  # Flush only OUTPUT in this namespace
  iptables -F OUTPUT || true

  # allow loopback
  iptables -A OUTPUT -o lo -j ACCEPT

  # allow established/related (LAN RPC replies still work)
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # allow root and other users (so healthchecks/diagnostics still function if needed)
  # (You can tighten this later if you want.)
  iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT

  # allow monero user only to Tor SOCKS
  iptables -A OUTPUT -m owner --uid-owner "${MONERO_UID}" -p tcp -d "${TOR_IP}" --dport "${TOR_SOCKS_PORT}" -j ACCEPT

  # block everything else from monero user
  iptables -A OUTPUT -m owner --uid-owner "${MONERO_UID}" -j REJECT --reject-with icmp-port-unreachable

  echo "[fw] OUTPUT rules:"
  iptables -S OUTPUT
else
  echo "[fw] ENFORCE_TOR_EGRESS=0 (no egress enforcement)."
fi

# ----------------------------
# Build monerod args
# ----------------------------
ARGS=(
  --data-dir "${DATA_DIR}"
  --non-interactive
  --no-igd
  --log-level "${LOG_LEVEL}"

  --p2p-bind-ip "${P2P_BIND_IP}"
  --p2p-bind-port "${P2P_PORT}"

  --rpc-bind-ip "${RPC_BIND_IP}"
  --rpc-bind-port "${RPC_PORT}"
  --confirm-external-bind

  # Route outbound networking via Tor SOCKS
  --proxy "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}"
  --proxy-allow-dns-leaks 0
  --tx-proxy "tor,${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT},disable_noise"
)

if [[ "${PRUNE_BLOCKCHAIN}" == "1" ]]; then
  ARGS+=( --prune-blockchain )
fi

if [[ "${RESTRICTED_RPC}" == "1" ]]; then
  ARGS+=( --restricted-rpc )
fi

if [[ -n "${RPC_LOGIN}" ]]; then
  ARGS+=( --rpc-login "${RPC_LOGIN}" )
fi

echo "[init] starting monerod (WAN via Tor SOCKS; wallet RPC via LAN/host port binding)."
exec gosu monero monerod "${ARGS[@]}" </dev/null
