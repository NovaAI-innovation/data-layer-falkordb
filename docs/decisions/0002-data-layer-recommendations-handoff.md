# 0002 — Data-Layer Recommendations Handoff

> Status: ACTIVE — captures the 4-phase (+0 hygiene) plan from the
> data-layer architecture review. This is a handoff document, not an
> implementation. Future sessions resuming after context compaction
> should start here.

## 0. Scope (MVP framework set)

The MVP framework set for `data-layer-adapters` is **agent-zero + hermes-agent only**.
**langchain and crewai are NOT in the MVP** and are not planned.
Per-framework MCP tool variants (`mcp/tools/<framework>/`) only ever need
`agent-zero/` and `hermes-agent/` subdirs.

**Stale references to remove (hygiene):**
- `data-layer-adapters/README.md` — lines mentioning `langchain/` and
  `crewai/` as "future" under the layout tree.
- `data-layer-adapters/AGENTS.md` — the parenthetical
  `(langchain/, crewai/)` in the "Future framework adapters" line.
  Replace with "No additional framework adapters are planned for MVP."

## 1. Current state on hermes (as of last verified run)

- `falkordb-test-sandbox` container is **Up**, persistent
  (`falkordb-test-sandbox-data` volume).
- Port mapping: `0.0.0.0:6379->6379/tcp` (FalkorDB RESP, the real engine),
  `0.0.0.0:7687->7687/tcp` (Next.js web UI), `0.0.0.0:3000->3000/tcp`.
- Schema: 10 CREATE NODE/EDGE TABLE statements skipped (FalkorDB schema is
  implicit, no DDL). `_SchemaMigrations` sentinel registered at version
  `0002_edges`.
- Node counts: 2 Framework, 1 Project, 2 Agent, 2 Tool, 3 Session,
  5 Message, 1 ToolExecution.
- Edge counts: 2 OWNS_AGENT, 3 OWNS_SESSION, 2 OWNS_TOOL,
  3 SENT_MESSAGE, 1 RAN_TOOL.
- Side-by-side SQL vs Cypher Q1/Q2/Q4 row counts MATCH. Q3/Q5 differ
  semantically (graph filters via `RAN_TOOL` edge vs SQL joins).

## 2. Phase 0 — Documentation + hygiene (≤ 30 min, fully durable)

### Hygiene edits
1. `data-layer-adapters/README.md` — remove `langchain/` and `crewai/`
   entries under the layout tree.
2. `data-layer-adapters/AGENTS.md` — remove the
   "Future framework adapters (`langchain/`, `crewai/`) follow the same
   shape" line. Replace with "No additional framework adapters are
   planned for MVP. Adding one would require a new ADR."

### ADRs to author (append-only per project convention)

| File | Captures |
|---|---|
| `data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md` | Rule: audit-grade ephemeral state → postgres; operational-only → redis. Candidate migrations: 0004 session_presence, 0005 tool_executions_lifecycle, 0006 idempotency_keys, 0007 rate_limit_events, 0008 lock_audit. |
| `data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md` | Dual-write postgres + falkordb. `redis_publish_hook()` interface. Phase 1 = session presence. Phase 2 = in-flight tool executions + recent messages. Lock tokens, counters, pub/sub, working blobs stay redis-only. |
| `data-layer-redis/docs/decisions/0001-key-pattern-catalog.md` | Catalog every redis key family with: stays-only-in-redis / promoted-to-postgres / projected-to-falkordb / TTL class. |

## 3. Phase 1 — Migrations (additive, low risk, ~1–2 h)

All in `data-layer-postgres/migrations/` (append-only, per
`data-layer-postgres/AGENTS.md`):

| Migration | Purpose | Status |
|---|---|---|
| `0004_session_presence.sql` | `sessions.last_heartbeat_at` column or new `session_heartbeats` table. | new |
| `0005_tool_executions_lifecycle.sql` | `tool_executions.started_at`, `arguments` columns (currently only completion is recorded). | new |
| `0006_idempotency_keys.sql` | New table; TTL becomes a vacuum job instead of a correctness boundary. | new |
| (deferred: 0007, 0008) | Rate-limit events, lock audit. | ADR-locked only |

## 4. Phase 2 — Adapter skeleton (~2–3 h, framework-agnostic core)

Right home:
```
data-layer-adapters/
├── agent-zero/      (per-framework bootstrap + plugin + prompts + seeds)
├── hermes-agent/    (same shape)
└── mcp/             (UNIVERSAL MCP server — tool routing by name)
```

Files to add (no existing code to merge with):

| File | Purpose |
|---|---|
| `data-layer-adapters/lib/write_through.py` | Dual-write interface: `write(record) → postgres + falkordb`. |
| `data-layer-adapters/lib/redis_publish_hook.py` | Pub/sub listener on adapter's own redis writes; emits `GRAPH.QUERY` for matched projections. |
| `data-layer-adapters/mcp/server.py` extension | Add a `session.heartbeat` tool that exercises both write paths. |
| `data-layer-adapters/mcp/tools/agent-zero/session_presence.py` | First demo category (Phase 1 of the dual-write contract). |
| `data-layer-adapters/mcp/tools/hermes-agent/session_presence.py` | Mirror for hermes-agent. |

The universal MCP routing means both per-framework files can wrap the
same framework-agnostic core. **No langchain or crewai variants.**

## 5. Phase 3 — Cutover, flag-gated (~1 h per category)

For each promoted category:
1. Adapter writes to postgres first.
2. Adapter writes to redis as cache/hot-state.
3. Publish hook projects to falkordb.
4. Toggle: redis-only-fallback (flag off) / dual-path (flag on).
5. Cut one tenant at a time, then all.

**Order:**
session presence → tool executions → idempotency keys →
rate-limit events → lock audit.

## 6. Phase 4 — Observability (~1 h)

Per promoted category, lightweight counters:
- postgres-writes/s
- redis-writes/s
- falkordb-projection/s
- TTL-housekeeping lag (rows-eligible-vs-rows-deleted)

Skip the Prometheus exporter initially; revisit when usage justifies it.

## 7. Cross-cutting hygiene

1. Update `data-layer/bootstrap` dispatcher so `seed` subcommand knows
   about the new migrations.
2. Update `data-layer-redis/README.md` to point at the new
   key-pattern catalog.
3. Update `data-layer-falkordb/lib/install.sh` and
   `docs/graph-schema.md` to document the new `Session.last_heartbeat`
   property.
4. Add `data-layer-adapters/tests/dual_write_smoke.sh` — runs a sample
   write through the adapter and asserts presence in postgres + falkordb.

## 8. Out-of-scope (re-stated)

- langchain/crewai adapters — **never** in MVP.
- Lock tokens, pure cache, pub/sub, working blobs, current counters
  — stay redis-only by design (the ADR says so).
- Postgres RLS, statement timeouts, partitioning, monitoring, backup —
  operational polish, separate effort.

## 9. Decisions made in this conversation that any future session must respect

| Decision | Why |
|---|---|
| FalkorDB transport is RESP on TCP 6379 (NOT bolt 7687) | Port 7687 in the falkordb docker image is the embedded Next.js web UI; only 6379 is the database. |
| Neo4j-style `CREATE NODE TABLE` / `CREATE EDGE TABLE` are documented in migrations/*.cypher for readability but skipped at apply time | FalkorDB has no DDL for node/edge tables. Schema is implicit; labels and edge types are auto-created on first use. |
| FalkorDB rejects multi-statement Cypher in one `GRAPH.QUERY` call | Migration files must be split on `;` and each statement sent separately. |
| `_SchemaMigrations` is a singleton node, not a table | Same as above; falkordb has no tables. Property `version` is the cursor. |
| `lib/install.sh` defaults to bolt://localhost:7687 to preserve the original contract; bootstrap-test-sandbox forces redis://127.0.0.1:6379 | Backward compatibility for callers; explicit opt-in for the docker-based path. |
| `data-layer-falkordb/lib/install.sh bootstrap-test-sandbox` is the canonical deploy for the test sandbox | Idempotent: docker pull → rm existing container (preserving volume) → start with `-p 6379:6379 -p 7687:7687 -p 3000:3000` → apply migrations + sample data → leave container RUNNING. |
| Container must NOT be removed after testing | Per user directive; the testing sandbox is for observability. |
| MVP framework set = agent-zero + hermes-agent ONLY | Per user; langchain/crewai not in MVP, not on roadmap. |

## 10. What was NOT inspected (limits)

- `data-layer-redis/docs/cache-abstraction.md` — the canonical redis
  key patterns; the key-pattern catalog ADR needs this.
- `data-layer-postgres/migrations/` — not enumerated; if
  `tool_executions.started_at` or `idempotency_keys` already exist from
  prior work, the new migrations collapse.
- `data-layer-adapters/mcp/server.py` — not opened; if the MCP server
  already has a hook surface, Phase 2 changes shape.
- `data-layer-adapters/agent-zero/bootstrap` and
  `data-layer-adapters/hermes-agent/bootstrap` — not opened; if their
  `seed` already does some dual-writes, the per-adapter cutover list
  changes.

## 11. Resumption checklist (next session starts here)

1. Read this file.
2. Read `data-layer-adapters/README.md` and confirm the hygiene edits
   in Phase 0 have been made.
3. Read `data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`
   (if it exists; if not, write it as Phase 0 step).
4. Read `data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`
   (if it exists; if not, write it as Phase 0 step).
5. Read `data-layer-redis/docs/decisions/0001-key-pattern-catalog.md`
   (if it exists; if not, write it as Phase 0 step).
6. Confirm `falkordb-test-sandbox` container is still Up on hermes via
   `ssh root@100.64.49.70 'docker ps --filter name=falkordb-test-sandbox'`.
7. Pick up at the next phase not yet completed.