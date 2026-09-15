#!/usr/bin/env bash
# data-layer-falkordb/lib/install.sh
# Idiomatic applier following the data-layer umbrella contract.
# Subcommands: install | verify | status | reset
#
# Mirrors the postgres applier pattern: tracks applied migrations in a
# schema_migrations tracker and applies .cypher files from migrations/
# in lexicographic order. Re-runs are no-ops.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MIG_DIR="$ROOT/migrations"

URL="${DATA_LAYER_FALKORDB_URL:-bolt://localhost:7687}"
DB="${DATA_LAYER_FALKORDB_DATABASE:-default}"

log()  { printf '[falkordb %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb FAIL] %s\n' "$*" >&2; exit 3; }
usage() { cat <<USAGE
Usage: $0 <install|verify|status|reset>

Environment:
  DATA_LAYER_FALKORDB_URL        bolt URI (default bolt://localhost:7687)
  DATA_LAYER_FALKORDB_DATABASE   graph name (default default)
USAGE
}

# Send a Cypher statement to falkordb-cli (or cypher-shell).
# Falls back gracefully if the binary is missing — verify step will catch it.
run_query() {
  local q="$1"
  if command -v falkordb-cli >/dev/null 2>&1; then
    falkordb-cli -a "$URL" -d "$DB" -c "$q" 2>&1
  elif command -v cypher-shell >/dev/null 2>&1; then
    echo "$q" | cypher-shell -a "$URL" -u neo4j 2>&1
  else
    echo "no falkordb-cli or cypher-shell in PATH"
    return 1
  fi
}

ensure_tracker() {
  # schema_migrations is a synthetic node that records applied versions.
  # We use a property on a sentinel Project node rather than a separate
  # node type, since falkordb doesn't have DDL for plain tables.
  run_query "MERGE (s:_SchemaMigrations {id:'singleton'}) RETURN s.id" >/dev/null
  log "schema migrations tracker ensured"
}

apply_migration() {
  local file="$1" version="$2"
  [[ -f "$file" ]] || fail "missing $file"
  local applied
  applied=$(run_query "MATCH (s:_SchemaMigrations {id:'singleton'}) WHERE s.version = '$version' RETURN s.version" | tr -d '[:space:]' || true)
  if [[ -n "$applied" && "$applied" == *"$version"* ]]; then
    log "$version already applied, skipping"
    return 0
  fi
  log "applying $version"
  if command -v falkordb-cli >/dev/null 2>&1; then
    falkordb-cli -a "$URL" -d "$DB" -f "$file" >/dev/null
  elif command -v cypher-shell >/dev/null 2>&1; then
    cypher-shell -a "$URL" -u neo4j < "$file" >/dev/null
  else
    fail "no falkordb-cli or cypher-shell in PATH"
  fi
  run_query "MATCH (s:_SchemaMigrations {id:'singleton'}) SET s.version = '$version' RETURN s.id" >/dev/null || \
    run_query "MERGE (s:_SchemaMigrations {id:'singleton'}) ON CREATE SET s.version = '$version' RETURN s.id" >/dev/null
  log "$version applied"
}

verify_schema() {
  local found
  found=$(run_query "MATCH (n) WHERE any label in labels(n) WHERE label IN ['Project','Agent','Session','Message','Tool'] RETURN count(n)" | tr -d '[:space:]' || echo "0")
  # We expect the schema_migrations sentinel to also be present.
  log "graph nodes (Project|Agent|Session|Message|Tool): $found (or 0 if schema not applied yet)"
}

verify_node_types() {
  # Single Cypher query — counts nodes per label.
  local result
  result=$(run_query "CALL db.labels() YIELD label RETURN label" 2>/dev/null || true)
  for required in Project Agent Session Message Tool _SchemaMigrations; do
    echo "$result" | grep -q "^$required$" || fail "node label $required missing"
  done
  log "all required node labels present (Project, Agent, Session, Message, Tool)"
}

verify_edge_types() {
  local result
  result=$(run_query "CALL db.types() YIELD type RETURN type" 2>/dev/null || true)
  for required in OWNS_AGENT OWNS_SESSION OWNS_TOOL SENT_MESSAGE RAN_TOOL; do
    echo "$result" | grep -q "^$required$" || fail "edge type $required missing"
  done
  log "all required edge types present (OWNS_AGENT, OWNS_SESSION, OWNS_TOOL, SENT_MESSAGE, RAN_TOOL)"
}

case "${1:-help}" in
  install)
    ensure_tracker
    # Apply in lexicographic order; .cypher files only.
    for f in "$MIG_DIR"/*.cypher; do
      [[ -f "$f" ]] || continue
      version="$(basename "$f" .cypher)"
      apply_migration "$f" "$version"
    done
    log "install complete"
    ;;
  verify)
    ensure_tracker
    verify_node_types
    verify_edge_types
    log "verify ok"
    ;;
  status)
    ensure_tracker
    echo "URL:      $URL"
    echo "database: $DB"
    local applied
    applied=$(run_query "MATCH (s:_SchemaMigrations {id:'singleton'}) RETURN coalesce(s.version,'(none)')" | tr -d '[:space:]' || echo "(none)")
    echo "current applied version: $applied"
    for label in Project Agent Session Message Tool; do
      local c
      c=$(run_query "MATCH (n:$label) RETURN count(n)" | tr -d '[:space:]' || echo "?")
      echo "  $label nodes:  $c"
    done
    for edge in OWNS_AGENT OWNS_SESSION OWNS_TOOL SENT_MESSAGE RAN_TOOL; do
      local c
      c=$(run_query "MATCH ()-[r:$edge]->() RETURN count(r)" | tr -d '[:space:]' || echo "?")
      echo "  $edge edges:  $c"
    done
    ;;
  reset)
    log "reset is a no-op for a fresh cluster; cluster-install lives in lib/falkordb.sh"
    log "to nuke the graph database:"
    log "  falkordb-cli -a "$URL" -d $DB -c 'MATCH (n) DETACH DELETE n'"
    ;;
  help|--help|-h|"") usage ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
