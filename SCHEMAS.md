# data-layer-falkordb — SCHEMAS.md

FalkorDB is the derived graph layer for the data-layer stack. Per `../docs/SUBMODULE_OWNERSHIP.md` rule #1 (no cross-submodule imports) and rule #3 (the umbrella does not own service-level logic), `data-layer-falkordb` owns its own node labels, edge types, Cypher migrations, and the bolt / RESP contract; every other layer (postgres durable rows, redis hot cache, qdrant vectors, framework adapters) projects into the graph through the adapter write-through path documented in `../data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`.

This document mirrors the 5-dimension shape used by `../data-layer-postgres/SCHEMAS.md`:
**property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled**.

## Schema-authority rule (binding)

The `migrations/*.cypher` files are the canonical schema. If this document and a migration disagree, the migration wins; update the doc in the same change.

> FalkorDB-specific: `CREATE NODE TABLE` / `CREATE EDGE TABLE` statements in the migrations are Neo4j/Memgraph syntax, kept for readability. FalkorDB has no DDL for node/edge tables — labels and edge types are auto-created on first use. The applier (`lib/install.sh` for bolt, `lib/bootstrap_payload.py` for RESP) detects the DDL prefix and skips those statements at apply time. See ADR `docs/decisions/0002-data-layer-recommendations-handoff.md` §9 for the explicit decision.

---

## 1. Inventory (node labels + edge types)

### 1.1 Node labels (declared in `migrations/0001_nodes.cypher`)

| Label | Mirrors postgres table | Identity | Applied by |
|---|---|---|---|
| `Project` | `projects` | `id` STRING (matches `projects.id` UUID) | bootstrap applier |
| `Agent` | `agents` | `id` STRING (matches `agents.id` UUID); business key `(framework_id, framework_local_id, deployment)` | bootstrap applier |
| `Session` | `sessions` | `id` STRING (matches `sessions.id` UUID) | bootstrap applier |
| `Message` | `messages` | `id` STRING (matches `messages.id` UUID) | bootstrap applier |
| `Tool` | `available_tools` | `id` STRING (matches `available_tools.id` UUID) | bootstrap applier |

### 1.2 Node labels (auto-created at runtime, NOT in migrations)

| Label | Created by | Notes |
|---|---|---|
| `_SchemaMigrations` | `lib/install.sh` / `lib/bootstrap_payload.py` | singleton; `id='singleton'`, `version='0002_edges'` cursor |
| `Framework` | `lib/bootstrap_payload.py` seed (`MERGE (f:Framework ...)`) | seed-only; represents an `agent_frameworks` row from postgres |
| `ToolExecution` | `lib/bootstrap_payload.py` seed (`MERGE (te:ToolExecution ...)`) | seed-only; will mirror `tool_executions` once the dual-write path is wired (ADR `docs/decisions/0002-data-layer-recommendations-handoff.md` §3) |

### 1.3 Planned node labels (referenced in `../docs/SUBMODULE_OWNERSHIP.md` §29, not yet in migrations)

| Label | Purpose | Trigger to add |
|---|---|---|
| `Email` | mirror `data-layer-postgres.emails`; provides graph-side thread traversal via `emails.thread_id` join key | Phase 2 of the dual-write plan; once `data-layer-adapters/lib/write_through.py` projects email rows into the graph |

### 1.4 Edge types (declared in `migrations/0002_edges.cypher`)

| Type | From → To | Properties |
|---|---|---|
| `OWNS_AGENT` | `Project` → `Agent` | `created_at` |
| `OWNS_SESSION` | `Agent` → `Session` | `created_at` |
| `OWNS_TOOL` | `Agent` → `Tool` | `granted_at` |
| `SENT_MESSAGE` | `Session` → `Session` (self-edge for self-messages) | `message_id`, `sent_at` |
| `RAN_TOOL` | `Session` → `Tool` | `tool_execution_id`, `started_at` |

### 1.5 Planned edge types (referenced in `../docs/SUBMODULE_OWNERSHIP.md` §29, not yet in migrations)

| Type | Source → Target | Notes |
|---|---|---|
| `INVOKED` | `Session` → `Tool` (or `Agent` → `Tool`) | semantic rename candidate for `RAN_TOOL` once the adapter projection is formalised; currently `RAN_TOOL` is the applied edge |
| `BELONGS_TO` | `Agent` → `Project` (or `Email` → `Project`) | equivalent to `OWNS_AGENT` traversed in reverse; `BELONGS_TO` is the umbrella-doc naming |
| `REFERENCES` | `Message` → `Message` (self-FK) | mirror of `messages.parent_message_id`; equivalent to `SENT_MESSAGE` semantics when threaded |
| `REPLIED_TO` | `Message` → `Message` (or `Email` → `Email`) | mirror of `emails.in_reply_to`; will use `emails.thread_id` as the cross-postgres join key (see §13 of `data-layer-postgres/SCHEMAS.md`) |

> The umbrella `SUBMODULE_OWNERSHIP.md` names the canonical edge vocabulary; the migration-applied set is a strict subset pending the dual-write cutover (see §3 below).

---

## 2. Per-node-label sections

Every row mirrors the `data-layer-postgres/SCHEMAS.md` 5-dim shape: **property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled**.

### 2.1 `Project` (`migrations/0001_nodes.cypher`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | internal id, joins to `projects.id` (UUID) | uuid | traversal seed; cross-store join key | immutable | `MATCH (p:Project {id: $uuid})` |
| `project_key` | `STRING` | business slug (`'data-layer-demo'`) | text | project lookup | updated only via rename migration | equality |
| `display_name` | `STRING` | human label | text | UI display | editable | ILIKE / regex |
| `status` | `STRING` DEFAULT `'active'` | lifecycle | `'active'` / `'archived'` | `MATCH (p:Project {status:'active'})` | transitions | equality |
| `created_at` | `DATETIME` DEFAULT `now()` | audit lineage | falkordb wall-clock | range filters | immutable | range |
| `metadata` | `STRING` DEFAULT `'{}'` | free-form JSON-as-text | `'{}'` | tenant tags | merged on update | `toString(...)` / regex |

### 2.2 `Agent` (`migrations/0001_nodes.cypher`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | internal id, joins to `agents.id` (UUID) | uuid | traversal seed; cross-store join key | immutable | `MATCH (a:Agent {id: $uuid})` |
| `project_id` | `STRING` | FK mirror to `projects.id` | uuid | tenant scoping | immutable | equality |
| `framework_id` | `STRING` | FK mirror to `agent_frameworks.id` | uuid | adapter dispatch key | immutable | equality |
| `framework_local_id` | `STRING` | per-framework agent id | text | adapter-side id | immutable | equality |
| `deployment` | `STRING` DEFAULT `''` | multi-deployment partition tag | text | cross-deploy collision guard | immutable | equality |
| `display_name` | `STRING` | human label | text | UI display | editable | ILIKE |
| `profile_key` | `STRING` | agent profile key (`'a0'`, `'hermes'`) | text | profile lookup | editable | equality |
| `status` | `STRING` DEFAULT `'active'` | lifecycle | text | `MATCH (a:Agent {status:'active'})` | transitions | equality |
| `created_at` | `DATETIME` DEFAULT `now()` | audit lineage | falkordb wall-clock | range | immutable | range |
| `metadata` | `STRING` DEFAULT `'{}'` | free-form JSON-as-text | `'{}'` | per-agent JSON | merged | regex |

> Business-key uniqueness `UNIQUE (framework_id, framework_local_id, deployment)` is enforced at the postgres layer (`data-layer-postgres/migrations/0002_alter_agents.sql`); the graph mirrors it for read-side joins only.

### 2.3 `Session` (`migrations/0001_nodes.cypher`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | internal id, joins to `sessions.id` (UUID) | uuid | traversal seed; cross-store join key | immutable | `MATCH (s:Session {id: $uuid})` |
| `agent_id` | `STRING` | FK mirror to `agents.id` | uuid | agent scoping | immutable | equality |
| `session_key` | `STRING` | per-agent session key | text | session lookup | editable | equality |
| `status` | `STRING` DEFAULT `'active'` | lifecycle (`'active'`, `'closed'`) | text | `MATCH (s:Session {status:'active'})` | transitions | equality |
| `started_at` | `DATETIME` DEFAULT `now()` | session start wall-clock | timestamp | range | immutable | range |
| `ended_at` | `DATETIME` | session end (nullable while open) | timestamp | duration calc | set on close | range |
| `metadata` | `STRING` DEFAULT `'{}'` | free-form JSON-as-text | `'{}'` | per-session JSON | merged | regex |

#### 2.3.1 Runtime-promoted `Session` properties (written by adapter, NOT by migration)

These properties are set by `data-layer-adapters/lib/redis_publish_hook.py` from MERGE statements emitted by the `session.heartbeat` projection (`data-layer-adapters/lib/write_through.py:session_heartbeat_record`). They are not in `migrations/0001_nodes.cypher`; they are documented here so traversals like `MATCH (s:Session) WHERE s.last_heartbeat_at > $cutoff` work without touching redis.

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `last_heartbeat_at` | `DATETIME` | mirrors `sessions.last_heartbeat_at` (postgres migration 0004) | timestamp | canonical cross-store presence signal; `WHERE last_heartbeat_at > $cutoff` | written by adapter projection on each heartbeat event | range + partial presence queries |
| `last_heartbeat_source` | `STRING` | mirrors `session_heartbeats.source` | `'adapter'` / `'replay'` / `'import'` | trust + replay-scope filter | written by adapter projection | equality |

### 2.4 `Message` (`migrations/0001_nodes.cypher`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | internal id, joins to `messages.id` (UUID) | uuid | traversal seed; cross-store join key | immutable | `MATCH (m:Message {id: $uuid})` |
| `session_id` | `STRING` | FK mirror to `sessions.id` | uuid | session scoping | immutable | equality |
| `agent_id` | `STRING` | FK mirror to `agents.id` | uuid | agent scoping | immutable | equality |
| `direction` | `STRING` | traffic direction (`'in'`, `'out'`) | text | direction filter | immutable | equality |
| `role` | `STRING` | LLM role (`'user'`, `'assistant'`, `'tool'`, `'system'`) | text | role filter | immutable | equality |
| `peer_agent_id` | `STRING` | counterparty (nullable) | uuid | cross-agent thread join | set on receive | equality |
| `content` | `STRING` | the message body | text | graph-side content search (use postgres `match_messages()` for semantic recall) | immutable | ILIKE / regex |
| `content_type` | `STRING` DEFAULT `'text'` | MIME-ish type | text | filter by type | immutable | equality |
| `thread_id` | `STRING` | conversation id; **joins to `data-layer-postgres.emails.thread_id` (UUID)** — see `data-layer-postgres/SCHEMAS.md` §13 | uuid | cross-store thread reconstruction; planned `Email` node join | immutable | equality |
| `parent_message_id` | `STRING` | self-thread mirror of `messages.parent_message_id` (self-FK) | uuid | in-conversation tree | immutable | equality (recursive traversal) |
| `created_at` | `DATETIME` DEFAULT `now()` | audit | timestamp | range | immutable | range |
| `external_ref` | `STRING` DEFAULT `'{}'` | provider metadata JSON-as-text | `'{}'` | cross-system correlation | merged | regex |

### 2.5 `Tool` (`migrations/0001_nodes.cypher`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | internal id, joins to `available_tools.id` (UUID) | uuid | traversal seed; cross-store join key | immutable | `MATCH (t:Tool {id: $uuid})` |
| `agent_id` | `STRING` | FK mirror to `agents.id` | uuid | grant scoping | immutable | equality |
| `tool_key` | `STRING` | tool identifier (`'execute_sql'`, `'mcp_recall'`) | text | tool lookup | editable | equality |
| `category` | `STRING` | grouping (`'data'`, `'memory'`) | text | UI taxonomy | editable | equality |
| `version` | `STRING` | semver | text | upgrade gate | updated on bump | equality |
| `manifest` | `STRING` DEFAULT `'{}'` | per-tool JSON-as-text | `'{}'` | adapter config | merged | regex |
| `granted_at` | `DATETIME` DEFAULT `now()` | grant audit | timestamp | range | immutable | range |
| `revoked_at` | `DATETIME` | revocation (nullable while active) | timestamp | time-bounded grant filter `revoked_at IS NULL` | set on revoke | range + NULL-check |
| `metadata` | `STRING` DEFAULT `'{}'` | free-form JSON-as-text | `'{}'` | per-tool JSON | merged | regex |

### 2.6 `_SchemaMigrations` (singleton, runtime)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` | primary key; always `'singleton'` | text | sentinel existence check | immutable | `MATCH (s:_SchemaMigrations {id:'singleton'})` |
| `version` | `STRING` | highest applied migration cursor (`'0000_init'`, `'0001_nodes'`, `'0002_edges'`) | text | gates future migration apply (`lib/install.sh` `apply_migration_file` skips files `<= version`) | updated on each migration | equality |

### 2.7 `Framework` (seed-only; from `lib/bootstrap_payload.py`)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` | primary key (UUID) | uuid | traversal seed | immutable | `MATCH (f:Framework {id: $uuid})` |
| `kind` | `STRING` | framework kind (`'agent_zero'`, `'hermes'`) | text | adapter dispatch | immutable | equality |
| `display_name` | `STRING` | human label | text | UI display | immutable | regex |
| `version` | `STRING` | framework version | text | version filter | immutable | equality |

### 2.8 `ToolExecution` (seed-only; future projection)

> Seeded by `lib/bootstrap_payload.py` for the test sandbox; the production dual-write path is not yet wired (see §3 below).

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` | primary key (UUID); will mirror `tool_executions.id` | uuid | traversal seed | immutable | `MATCH (te:ToolExecution {id: $uuid})` |
| `agent_id` | `STRING` | mirror `tool_executions.agent_id` | uuid | agent scoping | immutable | equality |
| `session_id` | `STRING` | mirror `tool_executions.session_id` | uuid | session scoping | immutable | equality |
| `message_id` | `STRING` | mirror `tool_executions.message_id` | uuid | message correlation | immutable | equality |
| `tool_name` | `STRING` | mirror `tool_executions.tool_name` | text | grant check + reporting | immutable | equality |
| `arguments` | `STRING` | JSON-as-text mirror of `tool_executions.arguments` | text | forensic | immutable | regex |
| `status` | `STRING` | lifecycle (`'pending'`, `'success'`, `'error'`, `'blocked'`) | text | retry/dedupe decisions | transitions | equality |
| `duration_ms` | `INTEGER` (seed value) | latency | int | range | computed | range |

### 2.9 `Email` (planned)

> Planned node label per `../docs/SUBMODULE_OWNERSHIP.md` §29. Not yet in `migrations/`. Triggered by Phase 2 of the dual-write plan. The primary cross-postgres join key is `data-layer-postgres.emails.thread_id` (see `data-layer-postgres/SCHEMAS.md` §13).

| property_name (planned) | type (planned) | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `id` | `STRING` PRIMARY KEY | mirror `emails.id` (UUID) | uuid | traversal seed | immutable | `MATCH (e:Email {id: $uuid})` |
| `thread_id` | `STRING` | mirror `emails.thread_id`; cross-postgres join key | uuid | thread reconstruction; joins to `Message.thread_id` for cross-channel threads | immutable | equality |
| `direction` | `STRING` | `'in'` / `'out'` | text | direction filter | immutable | equality |
| `message_id` | `STRING` | RFC 5322 Message-ID | text | dedupe | immutable | equality |
| `in_reply_to` | `STRING` | parent Message-ID | text | thread reconstruction | immutable | equality |
| `from_email` | `STRING` | sender | text | identity | immutable | ILIKE |
| `subject` | `STRING` | human label | text | display + search | immutable | ILIKE |
| `received_at`, `sent_at`, `ingested_at` | `DATETIME` | audit timestamps | timestamp | range | immutable | range |

---

## 3. Per-edge-type sections

Every row mirrors the 5-dim shape: **property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled**.

### 3.1 `OWNS_AGENT` (`migrations/0002_edges.cypher`)

- source_label: `Project`
- target_label: `Agent`

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `created_at` | `DATETIME` DEFAULT `now()` | grant lineage | timestamp | range | immutable | range |

> Traversal: `MATCH (p:Project {project_key:$k})-[:OWNS_AGENT]->(a:Agent) RETURN a`.

### 3.2 `OWNS_SESSION` (`migrations/0002_edges.cypher`)

- source_label: `Agent`
- target_label: `Session`

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `created_at` | `DATETIME` DEFAULT `now()` | session ownership timestamp | timestamp | range | immutable | range |

> Traversal: `MATCH (a:Agent {framework_local_id:$id})-[:OWNS_SESSION]->(s:Session) RETURN s`.

### 3.3 `OWNS_TOOL` (`migrations/0002_edges.cypher`)

- source_label: `Agent`
- target_label: `Tool`

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `granted_at` | `DATETIME` DEFAULT `now()` | grant lineage | timestamp | range; revoke-window queries | immutable | range |

> Traversal: `MATCH (a:Agent {id:$uuid})-[:OWNS_TOOL]->(t:Tool {tool_key:$k})`.

### 3.4 `SENT_MESSAGE` (`migrations/0002_edges.cypher`)

- source_label: `Session`
- target_label: `Session` (self-edge permitted for self-message)

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `message_id` | `STRING` | FK-style join to the `Message` node that this edge carries | uuid (as text) | per-message edge filter | immutable | equality |
| `sent_at` | `DATETIME` DEFAULT `now()` | send timestamp | timestamp | conversation ordering; range | immutable | range |

> Traversal: `MATCH (a:Agent)-[:OWNS_SESSION]->(s1:Session)-[:SENT_MESSAGE]->(s2:Session)<-[:OWNS_SESSION]-(b:Agent)`.

### 3.5 `RAN_TOOL` (`migrations/0002_edges.cypher`)

- source_label: `Session`
- target_label: `Tool`

| property_name | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|
| `tool_execution_id` | `STRING` | FK-style join to the future `ToolExecution` node | uuid (as text) | per-execution edge filter | immutable | equality |
| `started_at` | `DATETIME` DEFAULT `now()` | execution start | timestamp | latency analysis; range | immutable | range |

> Traversal: `MATCH (s:Session {id:$uuid})-[:RAN_TOOL]->(t:Tool {tool_key:$k}) RETURN count(t)`.

### 3.6 Planned edge types (referenced in `../docs/SUBMODULE_OWNERSHIP.md` §29, not yet in migrations)

| Edge | source → target | property_name (planned) | type | purpose | value | retrieval impact | mutation/transformation | queries enabled |
|---|---|---|---|---|---|---|---|---|
| `INVOKED` | `Session` → `Tool` (or `Agent` → `Tool`) | `invoked_at` | `DATETIME` | semantic rename of `RAN_TOOL` once dual-write is live | timestamp | tool-call analytics | transitions | range |
| `BELONGS_TO` | `Agent` → `Project` | `attached_at` | `DATETIME` | reverse of `OWNS_AGENT` | timestamp | multi-tenant filters | immutable | range |
| `REFERENCES` | `Message` → `Message` (self-FK) | `parent_message_id` | `STRING` | mirror of `messages.parent_message_id` | uuid | in-conversation tree | immutable | recursive CTE-equivalent in Cypher |
| `REPLIED_TO` | `Message` → `Message` (or `Email` → `Email`) | `replied_at` | `DATETIME` | mirror of `emails.in_reply_to` | timestamp | thread reconstruction across postgres + falkordb | immutable | range + `thread_id` join |

---

## 4. Cypher migrations

Applied in lexicographic order by `lib/install.sh install` (bolt) or `lib/bootstrap_payload.py` (RESP). The cursor lives on the `_SchemaMigrations` singleton node (`version='0002_edges'` after apply).

| File | Version cursor | Schema delta | Applier behaviour |
|---|---|---|---|
| `migrations/0001_nodes.cypher` | `0001_nodes` | declares 5 node tables: `Project`, `Agent`, `Session`, `Message`, `Tool` | bolt: split-on-`;`, sent via `GRAPH.QUERY`; DDL-prefix statements (`CREATE NODE TABLE …`) are skipped by `lib/bootstrap_payload.py` (FalkorDB has no DDL). RESP: same path through `lib/bootstrap_payload.py`. |
| `migrations/0002_edges.cypher` | `0002_edges` | declares 5 edge tables: `OWNS_AGENT`, `OWNS_SESSION`, `OWNS_TOOL`, `SENT_MESSAGE`, `RAN_TOOL` | same as above; DDL-prefix statements skipped. |

> FalkorDB has no DDL. Labels and edge types are auto-created on first use. The `CREATE NODE TABLE IF NOT EXISTS` / `CREATE EDGE TABLE IF NOT EXISTS` statements are kept in the migrations as the schema-of-record, but they are NOOP at apply time — see ADR `docs/decisions/0002-data-layer-recommendations-handoff.md` §9.

Idempotency surface:

- `lib/install.sh install` reads `_SchemaMigrations.version`; only files with basename strictly greater than the cursor are applied.
- `lib/bootstrap_payload.py` runs after a fresh container start; it deletes the graph (`GRAPH.DELETE`) before re-applying migrations + sample data, then re-registers `_SchemaMigrations { version: '0002_edges' }`.
- The two appliers are interchangeable for the same graph; bolt (`falkordb-cli` / `cypher-shell`) is the documented contract; RESP (`lib/bootstrap_payload.py`) is the test-sandbox path. Per `docs/SUBMODULE_OWNERSHIP.md` rule #1, the umbrella never imports the applier — it shells out via `bash data-layer-falkordb/lib/install.sh <subcommand>`.

---

## 5. Derivation contract

### 5.1 Sources of truth (postgres)

| Graph node/edge | Postgres source-of-truth table | Projector |
|---|---|---|
| `Project` | `data-layer-postgres.projects` | bootstrap applier + dual-write adapter |
| `Agent` | `data-layer-postgres.agents` | bootstrap applier + dual-write adapter |
| `Session` | `data-layer-postgres.sessions` | bootstrap applier + dual-write adapter; `last_heartbeat_*` from `data-layer-adapters/lib/write_through.py:session_heartbeat_record` |
| `Message` | `data-layer-postgres.messages` | dual-write adapter |
| `Tool` | `data-layer-postgres.available_tools` | bootstrap applier + dual-write adapter |
| `ToolExecution` (seed / planned) | `data-layer-postgres.tool_executions` | planned Phase 2 dual-write |
| `Email` (planned) | `data-layer-postgres.emails` (see `data-layer-postgres/SCHEMAS.md` §13) | planned Phase 2 dual-write; `thread_id` is the cross-postgres join key |
| `OWNS_AGENT` | `agents.project_id` FK | projector |
| `OWNS_SESSION` | `sessions.agent_id` FK | projector |
| `OWNS_TOOL` | `available_tools.agent_id` FK | projector |
| `SENT_MESSAGE` | derived from `messages` rows + optional peer correlation | projector |
| `RAN_TOOL` | `tool_executions.session_id` + `tool_executions.tool_name` (via the `Tool` label) | projector (planned Phase 2) |

### 5.2 Readers / consumers (MCP, lib scripts, queries)

- `data-layer-adapters/lib/write_through.py` — emits MERGE statements that populate node/edge properties on each adapter event.
- `data-layer-adapters/lib/redis_publish_hook.py` — projects the cache-side write to the graph (e.g., `Session.last_heartbeat_at`, `Session.last_heartbeat_source`).
- `data-layer-adapters/mcp/server.py` (planned, see ADR `0002-data-layer-recommendations-handoff.md` §4) — graph-backed MCP tools once the `session.heartbeat` projection is live.
- `data-layer-falkordb/lib/install.sh verify` — reads `db.labels()` / `db.types()` to confirm `Project`, `Agent`, `Session`, `Message`, `Tool`, `_SchemaMigrations` and `OWNS_AGENT`, `OWNS_SESSION`, `OWNS_TOOL`, `SENT_MESSAGE`, `RAN_TOOL` exist.
- `data-layer-falkordb/lib/install.sh status` — emits per-label and per-edge-type counts for the 5 declared nodes + 5 declared edges.
- `data-layer-falkordb/tests/smoke.sh` — runs `lib/install.sh verify` against a live falkordb.
- `data-layer-falkordb/lib/bootstrap_payload.py` — runs 4 smoke queries (`RETURN 1`, `MATCH (a:Agent)-[:OWNS_SESSION]->(s:Session)-[:RAN_TOOL]->(t:Tool) RETURN count(*)`, plus the migration sentinel query).

### 5.3 Cross-store join keys (postgres ↔ falkordb)

| Graph property | Postgres column | Use |
|---|---|---|
| `*.id` (all nodes) | `<table>.id` (`uuid`) | universal join key |
| `Message.thread_id` | `data-layer-postgres.emails.thread_id` (see §13 of postgres SCHEMAS.md) | cross-channel thread reconstruction once the `Email` node lands |
| `Session.last_heartbeat_at` | `data-layer-postgres.sessions.last_heartbeat_at` + `session_heartbeats.received_at` | canonical cross-store presence signal |
| `Tool.tool_key` | `data-layer-postgres.available_tools.tool_key` | tool lookup |

---

## 6. Wiring

- **Protocol:** FalkorDB speaks RESP on TCP 6379 (the real database) and Bolt on TCP 7687. The docker image also exposes a Next.js web UI on 3000. Per ADR `0002-data-layer-recommendations-handoff.md` §9, port 6379 is the database; port 7687 is the legacy bolt surface (default in `DATA_LAYER_FALKORDB_URL`); port 3000 is the UI.
- **Connection env (`.a0proj/variables.env`):** `DATA_LAYER_FALKORDB_URL=bolt://localhost:7687`, `DATA_LAYER_FALKORDB_DATABASE=default`.
- **Test sandbox:** `lib/install.sh bootstrap-test-sandbox` (delegates to `lib/bootstrap_payload.py` on RESP 6379) starts a `falkordb-test-sandbox` container and leaves it running for observability (see ADR §9).
- **Server install:** `lib/falkordb.sh` downloads the FalkorDB release tarball (default `v${DATA_LAYER_FALKORDB_VERSION:-1.2.0}`); see ADR `0001-falkordb-installer-uri-and-idempotency.md`.
- **Image install:** `lib/docker_image_install.sh` is a Docker Registry v2 fallback that pulls `falkordb.so`, `run.sh`, and `gen-certs.sh` from the official image when no daemon/HTTP API is available.
- **Docker image:** `Dockerfile` extends `falkordb/falkordb:latest`, copies `migrations/*.cypher` + `lib/bootstrap_payload.py` to `/opt/data-layer/`, and runs the custom entrypoint that applies migrations on first start.

---

## 7. Cross-links

- `../docs/SUBMODULE_OWNERSHIP.md` — submodule ownership matrix (rule #1 no cross-submodule imports; rule #3 umbrella does not own service-level logic).
- `../data-layer-postgres/SCHEMAS.md` §13 `emails` — the `thread_id` column is the join key between postgres `emails` and the falkordb graph (planned `Email` node + `REPLIED_TO` edge).
- `../data-layer-adapters/TOOLS_AND_WIRING.md` (when produced) — every MCP tool, lib script, and its wiring route.
- `docs/graph-schema.md` — companion narrative doc; documents the runtime-promoted `Session.last_heartbeat_*` properties and example traversals.
- `docs/decisions/0001-falkordb-installer-uri-and-idempotency.md` — server-install contract.
- `docs/decisions/0002-data-layer-recommendations-handoff.md` — the dual-write + redis publish hook plan; Phase 2 unlocks the `Email` / `ToolExecution` / `REPLIED_TO` / `REFERENCES` set.

---

## 8. What is intentionally NOT in this graph

- **Framework-specific node / edge types** (e.g., Agent Zero plugin graph, hermes-agent memory graph) live in `data-layer-adapters/<framework>/` if needed.
- **Seed rows for any specific framework** live in postgres; the graph derives from postgres state.
- **Plugin code, MCP wiring, agent runtime glue** are framework-adapter concerns, not graph-database concerns (per `../docs/SUBMODULE_OWNERSHIP.md` rule #1).
- **Audit-grade state** (e.g., heartbeats, idempotency keys, rate-limit events, lock audit) belongs in postgres (see `../data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`); falkordb only carries the projected view.

---

## 9. Schema-authority footer (binding)

The migrations win. If any section of this document disagrees with `migrations/0001_nodes.cypher`, `migrations/0002_edges.cypher`, or `lib/bootstrap_payload.py` seed data, the migration / applier is canonical and this doc must be updated in the same change. The umbrella's `SUBMODULE_OWNERSHIP.md` is the next-priority reference; the postgres `SCHEMAS.md` is the upstream source of truth for every property that mirrors a postgres column.
