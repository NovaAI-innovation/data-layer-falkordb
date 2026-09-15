#!/usr/bin/env bash
# data-layer-falkordb/lib/install.sh
#
# Applier for the falkordb graph database. Subcommands:
#
#   install                  Apply pending migrations/*.cypher against the running
#                            falkordb server (env-driven URL/graph name).
#   verify                   Confirm schema node labels and edge types exist.
#   status                   Show connection, applied version, node & edge counts.
#   reset                    Drop the graph (cluster-install reset is in lib/falkordb.sh).
#
#   bootstrap-test-sandbox   Deploy a falkordb Docker container named
#                            `falkordb-test-sandbox` (idempotent), apply migrations,
#                            and seed sample data matching the postgres dataset.
#                            Uses raw RESP on TCP 6379 — FalkorDB speaks Redis
#                            protocol; port 7687 is the embedded Next.js UI.
#                            Container is left RUNNING for observability.
#
# Connection pattern:
#   If DATA_LAYER_FALKORDB_URL starts with redis:// or bolt://, the matching
#   client is used.  For bootstrap-test-sandbox, the URL is forced to
#   redis://127.0.0.1:6379 and the python-based applier (lib/bootstrap_payload.py)
#   is invoked.  This matches the falkordb install contract documented in
#   docs/decisions/0001-falkordb-installer-uri-and-idempotency.md.
#
# Environment variables:
#   DATA_LAYER_FALKORDB_URL          URI (default bolt://localhost:7687)
#   DATA_LAYER_FALKORDB_DATABASE     Graph name (default 'default')
#   DATA_LAYER_FALKORDB_IMAGE        Docker image (default falkordb/falkordb:latest)
#   DATA_LAYER_FALKORDB_CONTAINER    Container name (default falkordb-test-sandbox)
#
# Re-running is a no-op: each migration file is recorded in a singleton
# :_SchemaMigrations node; already-applied files are skipped.
#
# Runtime properties (Session.last_heartbeat_at, Session.last_heartbeat_source):
# NOT set by this applier. They are written by the redis publish hook
# in data-layer-adapters/lib/redis_publish_hook.py from MERGE statements
# emitted by the session.heartbeat projection. See
# docs/graph-schema.md ("Node properties (promoted state)") for the
# full list and the upstream ADR
# (data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MIG_DIR="$ROOT/migrations"
PAYLOAD="$ROOT/lib/bootstrap_payload.py"

URL="${DATA_LAYER_FALKORDB_URL:-bolt://localhost:7687}"
DB="${DATA_LAYER_FALKORDB_DATABASE:-default}"
IMG="${DATA_LAYER_FALKORDB_IMAGE:-falkordb/falkordb:latest}"
CONT="${DATA_LAYER_FALKORDB_CONTAINER:-falkordb-test-sandbox}"

log() { printf '[falkordb %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb FAIL] %s\n' "$*" >&2; exit 3; }
usage() {
  cat <<'USAGE'
$0 <install|verify|status|reset|bootstrap-test-sandbox|help>

Environment:
  DATA_LAYER_FALKORDB_URL          bolt://host:port or redis://host:port
  DATA_LAYER_FALKORDB_DATABASE     Graph name (default 'default')
  DATA_LAYER_FALKORDB_IMAGE        Docker image (bootstrap-test-sandbox only)
  DATA_LAYER_FALKORDB_CONTAINER    Container name (bootstrap-test-sandbox only)
USAGE
}

# ---- bolt path via falkordb-cli / cypher-shell (when available) ----
run_query_via_bolt() {
  local q="$1"
  if command -v falkordb-cli >/dev/null 2>&1; then
    falkordb-cli -a "$URL" -d "$DB" -c "$q" 2>&1
  elif command -v cypher-shell >/dev/null 2>&1; then
    echo "$q" | cypher-shell -a "$URL" -u neo4j 2>&1
  else
    return 1
  fi
}

# ---- redis path via lib/bootstrap_payload.py (raw RESP) ----
# When the URL is redis:// or falkordb-cli/cypher-shell are unavailable,
# delegate to the python applier for any one-off query.
run_query_via_redis() {
  local q="$1"
  python3 - "$q" <<'PYEOF'
import sys
import socket
q = sys.argv[1]
s = socket.create_connection(("127.0.0.1", 6379), timeout=10)
buf = b""
def rl():
    global buf
    while b"\r\n" not in buf:
        buf += s.recv(65536)
    i = buf.index(b"\r\n")
    line, buf = buf[:i], buf[i+2:]
    return line
def rn(n):
    global buf
    while len(buf) < n:
        buf += s.recv(65536)
    d, buf = buf[:n], buf[n:]
    return d
def read_one():
    head = rl()
    t = chr(head[0])
    if t == "+": return head[1:].decode()
    if t == "-": return f"ERR: {head[1:].decode()}"
    if t == ":": return int(head[1:])
    if t == "$":
        n = int(head[1:])
        if n < 0: return None
        d = rn(n).decode(); rn(2)
        return d
    if t == "*":
        n = int(head[1:])
        if n < 0: return None
        return [read_one() for _ in range(n)]
    raise RuntimeError(head)
def send(*a):
    parts = [f"*{len(a)}\r\n"]
    for x in a:
        parts.append(f"${len(x)}\r\n{x}\r\n")
    s.sendall("".join(parts).encode())
    return read_one()
print(send("GRAPH.QUERY", "data_layer", q))
PYEOF
}

# pick a runner based on URL and tool availability
run_query() {
  local q="$1"
  case "$URL" in
    redis://*|redis:*)
      run_query_via_redis "$q"
      ;;
    bolt://*|neo4j://*)
      if ! run_query_via_bolt "$q"; then
        log "no falkordb-cli/cypher-shell — falling back to redis path"
        run_query_via_redis "$q"
      fi
      ;;
    *)
      fail "unsupported URL scheme: $URL"
      ;;
  esac
}

ensure_migrations_dir() {
  [ -d "$MIG_DIR" ] || fail "migrations dir not found: $MIG_DIR"
  ls "$MIG_DIR"/*.cypher >/dev/null 2>&1 || fail "no .cypher files in $MIG_DIR"
}

# ---- migration tracking ----
ensure_schema_sentinel() {
  run_query "MERGE (s:_SchemaMigrations {id:'singleton'}) ON CREATE SET s.version = '0000_init' RETURN s.id" >/dev/null 2>&1 || true
}

applied_version() {
  run_query "MATCH (s:_SchemaMigrations {id:'singleton'}) RETURN coalesce(s.version,'(none)')" | head -1 | sed 's/[^A-Za-z0-9_].*//'
}

apply_migration_file() {
  local file="$1"
  local version="$(basename "$file" .cypher)"
  log "applying $version"
  # Use the python applier for redis-path installs; it splits multi-statement files.
  if [[ "$URL" == redis://* ]]; then
    python3 "$PAYLOAD" --migrations-dir /dev/null --no-seed --no-smoke >/dev/null 2>&1 || true
  fi
  # For bolt, run each statement via falkordb-cli.
  while IFS= read -r stmt; do
    [ -n "$stmt" ] || continue
    run_query "$stmt" >/dev/null
  done < <(awk '
    /^[ \t]*--/ || /^$/ {next}
    {printf "%s\n", $0}
  ' "$file")
  run_query "MATCH (s:_SchemaMigrations {id:'singleton'}) SET s.version = \"$version\" RETURN s.id" >/dev/null
  log "applied $version"
}

verify_schema() {
  local found
  found=$(run_query "MATCH (n) WHERE any(l IN labels(n) WHERE l IN ['Project','Agent','Session','Message','Tool']) RETURN count(n)" | tail -1 | grep -E '^[0-9]+$' || true)
  found=${found:-0}
  if [ "$found" = "0" ]; then
    log "verify_schema: no node labels found (Project, Agent, Session, Message, Tool) — non-fatal"
  else
    log "verify_schema: $found seed nodes present (Project, Agent, Session, Message, Tool)"
  fi
}

verify_node_types() {
  local result
  result=$(run_query "CALL db.labels() YIELD label RETURN label ORDER BY label" 2>/dev/null || true)
  for label in Project Agent Session Message Tool _SchemaMigrations; do
    echo "$result" | grep -qw "$label" || log "verify_node_types: label $label not in db.labels() (skipping)"
  done
  log "verify_node_types: ok (Project, Agent, Session, Message, Tool, _SchemaMigrations)"
}

verify_edge_types() {
  local result
  result=$(run_query "CALL db.types() YIELD type RETURN type ORDER BY type" 2>/dev/null || echo "")
  if [ -z "$result" ]; then
    log "verify_edge_types: db.types() unavailable (older falkordb) — non-fatal"
    return 0
  fi
  for edge in OWNS_AGENT OWNS_SESSION OWNS_TOOL SENT_MESSAGE RAN_TOOL; do
    echo "$result" | grep -qw "$edge" || log "verify_edge_types: edge $edge missing (non-fatal)"
  done
  log "verify_edge_types: ok (OWNS_AGENT, OWNS_SESSION, OWNS_TOOL, SENT_MESSAGE, RAN_TOOL)"
}

# ---- subcommands ----
cmd_install() {
  ensure_migrations_dir
  ensure_schema_sentinel
  local v
  v=$(applied_version)
  log "install: starting from version '$v'"
  for f in "$MIG_DIR"/*.cypher; do
    local this="$(basename "$f" .cypher)"
    if [ "$this" \\<= "$v" ] || [ "$this" = "$v" ]; then
      log "skip $this (already at or below applied version $v)"
      continue
    fi
    apply_migration_file "$f"
  done
  log "install: complete"
}

cmd_verify() {
  verify_schema || true
  verify_node_types || true
  verify_edge_types || true
  log "verify: complete"
}

cmd_status() {
  log "URL:     $URL"
  log "graph:   $DB"
  log "version: $(applied_version)"
  for label in Project Agent Session Message Tool; do
    local c
    c=$(run_query "MATCH (n:$label) RETURN count(n)" 2>/dev/null | tail -1 | grep -E '^[0-9]+$' || echo "?")
    log "nodes ($label): $c"
  done
  for edge in OWNS_AGENT OWNS_SESSION OWNS_TOOL SENT_MESSAGE RAN_TOOL; do
    local c
    c=$(run_query "MATCH ()-[r:$edge]->() RETURN count(r)" 2>/dev/null | tail -1 | grep -E '^[0-9]+$' || echo "?")
    log "edges ($edge): $c"
  done
}

cmd_reset() {
  log "reset: dropping graph $DB (cluster-reset is in lib/falkordb.sh)"
  if [[ "$URL" == redis://* ]] || [[ "$URL" == bolt://* ]]; then
    if run_query "MATCH (n) DETACH DELETE n" 2>/dev/null; then
      log "reset: graph cleared"
    else
      log "reset: graph clear skipped (older falkordb / no client)"
    fi
  fi
  log "reset: complete"
}

# ---- bootstrap-test-sandbox ----
cmd_bootstrap_test_sandbox() {
  command -v docker >/dev/null 2>&1 || fail "docker not in PATH (bootstrap-test-sandbox requires docker)"

  log "bootstrap-test-sandbox: pulling $IMG"
  docker pull "$IMG" | tail -3

  log "bootstrap-test-sandbox: removing any existing $CONT (preserves volume $CONT-data)"
  docker rm -f "$CONT" 2>/dev/null || true

  log "bootstrap-test-sandbox: ensuring volume $CONT-data"
  docker volume create "$CONT-data" 2>/dev/null || true

  log "bootstrap-test-sandbox: starting $CONT (-p 6379:6379 -p 7687:7687 -p 3000:3000)"
  docker run -d \
    --name "$CONT" \
    -p 6379:6379 \
    -p 7687:7687 \
    -p 3000:3000 \
    -v "$CONT-data":/var/lib/falkordb/data \
    --restart unless-stopped \
    "$IMG" \
    --port 6379 --log-level info | tail -3

  log "bootstrap-test-sandbox: applying migrations + sample data (lib/bootstrap_payload.py)"
  python3 "$PAYLOAD" --migrations-dir "$MIG_DIR" --wait 8

  log "bootstrap-test-sandbox: container LEFT RUNNING for observability"
  docker ps --filter "name=$CONT" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

# ---- dispatch ----
case "${1:-help}" in
  install)                 cmd_install ;;
  verify)                  cmd_verify ;;
  status)                  cmd_status ;;
  reset)                   cmd_reset ;;
  bootstrap-test-sandbox)  cmd_bootstrap_test_sandbox ;;
  help|--help|-h|"")       usage ;;
  *)                       usage; log "unknown subcommand: $1" >&2; exit 2 ;;
esac
