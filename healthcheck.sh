#!/usr/bin/env sh
set -eu

: "${TOR_SOCKS_HOST:=tor}"
: "${TOR_SOCKS_PORT:=9050}"
: "${RPC_PORT:=18081}"
: "${RPC_LOGIN:=}"

# Tor reachable?
nc -z "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"

# monerod RPC reachable locally?
if [ -n "$RPC_LOGIN" ]; then
  curl -fsS --digest -u "$RPC_LOGIN" "http://127.0.0.1:${RPC_PORT}/get_height" >/dev/null
else
  curl -fsS "http://127.0.0.1:${RPC_PORT}/get_height" >/dev/null
fi
