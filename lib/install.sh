#!/usr/bin/env bash
# data-layer-falkordb/lib/install.sh
# Idiomatic applier following the data-layer umbrella contract.
# Subcommands: install | verify | status | reset
set -euo pipefail
URL="${DATA_LAYER_FALKORDB_URL:-bolt://localhost:7687}"
DB="${DATA_LAYER_FALKORDB_DATABASE:-default}"
log()  { printf '[falkordb %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb FAIL] %s\n' "$*" >&2; exit 3; }
usage() { cat <<USAGE
Usage: $0 <install|verify|status|reset>
USAGE
}
# Node + edge registration list (kept in sync with docs/graph-schema.md).
NODES=(Project Agent Session Tool)
EDGES=(OWNS_AGENT OWNS_SESSION OWNS_TOOL SENT_MESSAGE RAN_TOOL)
run_query() { falkordb-cli -a "$URL" -d "$DB" -c "$1" 2>/dev/null; }
case "${1:-help}" in
  install)
    log "creating graph database: $DB"
    run_query "CREATE DATABASE IF NOT EXISTS $DB" || log "(database already exists)"
    for n in "${NODES[@]}"; do
      log "registering node type: $n"
      run_query "CREATE NODE TABLE IF NOT EXISTS $n (id STRING PRIMARY BOOL)" || log "  (already registered)"
    done
    for e in "${EDGES[@]}"; do
      log "registering edge type: $e"
      run_query "CREATE EDGE TABLE IF NOT EXISTS $e" || log "  (already registered)"
    done
    log "install complete"
    ;;
  verify)
    pong=$(run_query "MATCH (n) RETURN count(n) LIMIT 1" || true)
    [[ -n "$pong" ]] || fail "bolt query failed against $URL"
    log "verify ok"
    ;;
  status)
    echo "URL:      $URL"
    echo "database: $DB"
    for n in "${NODES[@]}"; do
      c=$(run_query "MATCH (n:$n) RETURN count(n) LIMIT 1" || echo "?")
      echo "  $n nodes:  $c"
    done
    for e in "${EDGES[@]}"; do
      c=$(run_query "MATCH ()-[r:$e]->() RETURN count(r) LIMIT 1" || echo "?")
      echo "  $e edges:  $c"
    done
    ;;
  reset)
    log "reset would DROP the graph database $DB"
    log "(this is a destructive op; intended for test/dev)"
    ;;
  help|--help|-h|"") usage ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
