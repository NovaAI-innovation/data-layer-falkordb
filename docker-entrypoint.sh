#!/usr/bin/env bash
# data-layer-falkordb/docker-entrypoint.sh
#
# On first start:
#   1. Start the falkordb engine (redis-server + loadmodule falkordb.so).
#   2. Wait for raw RESP port (6379) to respond to PING.
#   3. Run the python bootstrap applier (idempotent).
#   4. Wait on the falkordb engine so the container stays up.

set -euo pipefail
FALKORDB_PORT="${FALKORDB_PORT:-6379}"
DATA_DIR="${FALKORDB_DATA_DIR:-/data}"
GRAPH="${DATA_LAYER_FALKORDB_DATABASE:-default}"
MIGRATIONS_DIR="/opt/data-layer/migrations"
APPLIER="/opt/data-layer/bootstrap_payload.py"

REDIS_SERVER=""
for cand in /usr/local/bin/redis-server /usr/bin/redis-server; do
    if [[ -x "$cand" ]]; then REDIS_SERVER="$cand"; break; fi
done
MODULE_PATH=""
for cand in /var/lib/falkordb/bin/falkordb.so /var/lib/falkordb/falkordb.so; do
    if [[ -f "$cand" ]]; then MODULE_PATH="$cand"; break; fi
done
if [[ -z "$REDIS_SERVER" || -z "$MODULE_PATH" ]]; then
    echo "[data-layer-falkordb FAIL] engine binaries missing" >&2
    exit 3
fi

echo "[data-layer-falkordb] engine: $REDIS_SERVER"
echo "[data-layer-falkordb] module: $MODULE_PATH"
mkdir -p "$DATA_DIR"
"$REDIS_SERVER" --port "$FALKORDB_PORT" --dir "$DATA_DIR" --loadmodule "$MODULE_PATH" &
ENGINE_PID=$!
trap 'kill -TERM "$ENGINE_PID" 2>/dev/null || true' EXIT

# Wait for raw RESP PING. python byte string literal is interpreted
# by Python, not by bash. The backslash-r + backslash-n chars are
# passed through to python3 which decodes them as CR + LF.
echo -n "[data-layer-falkordb] waiting for engine ready "
for i in $(seq 1 60); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', $FALKORDB_PORT)); s.sendall(b'PING\r\n'); sys.exit(0 if b'PONG' in s.recv(100) else 1)" 2>/dev/null; then
        echo "(ready after ${i}s)"
        break
    fi
    echo -n "."
    sleep 1
done

# Apply migrations + sample data (idempotent).
# bootstrap_payload.py uses --host, --port, --graph, --migrations-dir.
# Put the full command in { ... } group so the || fallback is scoped.
if [[ -f "$APPLIER" ]]; then
    echo "[data-layer-falkordb] applying migrations + seed via $APPLIER"
    { python3 "$APPLIER" \
        --host 127.0.0.1 \
        --port "$FALKORDB_PORT" \
        --graph "$GRAPH" \
        --migrations-dir "$MIGRATIONS_DIR"; } || echo "[data-layer-falkordb WARN] bootstrap_payload exited non-zero; continuing"
fi

echo "[data-layer-falkordb] ready; tailing engine (pid $ENGINE_PID)"
wait "$ENGINE_PID"
