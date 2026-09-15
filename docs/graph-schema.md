# FalkorDB graph schema (data-layer-falkordb)

**Scope.** This is the framework-agnostic graph layer for the data-layer
stack. It is parallel to `data-layer-postgres`: same identity contract,
same scope boundaries, same framework-agnostic posture. Framework-
specific code and seed rows live elsewhere (in
`data-layer-adapters/<framework>/`).

**Role.** `data-layer-postgres` is authoritative storage: every agent,
session, message, tool execution has a row. The graph layer adds
**traversal**: answering questions like "which agents worked on this
project?", "what tools did session X use?", "what's the path from
agent A's first message to its tool execution that solved the task?".
Traversals that require joins across multiple tables in postgres are
easy graph traversals here.

**Identity contract.** Same as postgres:

- `Agent.framework_local_id` + `Agent.deployment` form the
  framework-local identifier.
- `id` UUIDs are identical between postgres rows and the graph
  nodes — `MATCH (a:Agent {id: '...'})` joins directly to
  `agents.id` in postgres.

## Migrations

Cypher migration files live under `migrations/` and are applied in
lexicographic order by `lib/install.sh install`. Applied versions are
tracked on a sentinel `_SchemaMigrations` node.

```
migrations/
  0001_nodes.cypher   — Project, Agent, Session, Message, Tool
  0002_edges.cypher   — OWNS_AGENT, OWNS_SESSION, OWNS_TOOL, SENT_MESSAGE, RAN_TOOL
```

## Node types (mirrors postgres tables)

| Label | Mirrors postgres table | Identity |
|---|---|---|
| `Project` | `projects.id` | uuid PK |
| `Agent` | `agents.id` | uuid PK; `(framework_id, framework_local_id, deployment)` business key |
| `Session` | `sessions.id` | uuid PK |
| `Message` | `messages.id` | uuid PK |
| `Tool` | `available_tools.id` | uuid PK |

## Edge types (mirrors postgres relationships)

| Type | From → To | Properties |
|---|---|---|
| `OWNS_AGENT` | Project → Agent | `created_at` |
| `OWNS_SESSION` | Agent → Session | `created_at` |
| `OWNS_TOOL` | Agent → Tool | `granted_at` |
| `SENT_MESSAGE` | Session → Session | `message_id`, `sent_at` |
| `RAN_TOOL` | Session → Tool | `tool_execution_id`, `started_at` |

## Node properties (promoted state)

Properties below mirror columns added by the postgres migrations in
`data-layer-postgres/migrations/` (0004+). They are written by the
redis publish hook (see
`data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`)
from MERGE statements in
`data-layer-adapters/lib/write_through.py:session_heartbeat_record`.

| Label | Property | Source |
|---|---|---|
| `Session` | `last_heartbeat_at` | `sessions.last_heartbeat_at` (migration 0004) — written by `session.heartbeat` projection. |
| `Session` | `last_heartbeat_source` | `session_heartbeats.source` — `adapter` / `replay` / `import`. |

The `Session.last_heartbeat_at` property is the canonical cross-store
presence signal: postgres holds the audit trail in `session_heartbeats`,
redis caches the most-recent value, and falkordb holds the graph-side
mirror so traversals like `MATCH (s:Session) WHERE s.last_heartbeat_at > $cutoff`
work without touching either of the other stores.


## Example traversals

### All sessions in a project that ran tool X

```cypher
MATCH (p:Project {project_key:'default'})-[:OWNS_AGENT]->(a:Agent)
      -[:OWNS_SESSION]->(s:Session)
      -[:RAN_TOOL]->(t:Tool {tool_key:'execute_sql'})
RETURN s.id, s.started_at, count(t) AS tool_calls
ORDER BY s.started_at DESC
```

### Conversation thread between two agents (with tool use in between)

```cypher
MATCH (a1:Agent {framework_local_id: '52ba0cdf32af'})-[:OWNS_SESSION]->(s1:Session)
      -[:SENT_MESSAGE]->(s2:Session)<-[:OWNS_SESSION]-(a2:Agent)
RETURN s1, s2
```

### All projects an agent has touched (including via deployment tags)

```cypher
MATCH (a:Agent {framework_local_id: '52ba0cdf32af'})
MATCH (a)-[:OWNS_AGENT]-(p:Project)
   OR (p)-[:OWNS_AGENT]->(a2:Agent {deployment: a.deployment})
RETURN DISTINCT p
```

## Why both postgres and falkordb?

- **postgres** is the source of truth. Every write is durable, ACID,
  relational.
- **falkordb** is a denormalised projection optimised for traversal.
  Nodes and edges are derived from postgres state, written via the
  adapter layer when records change.
- The umbrella's `bootstrap` runs schema install on postgres first,
  then seeds framework rows via adapters, then runs schema install on
  falkordb (which creates the empty graph skeleton). The graph layer
  populates as adapters emit messages.

## What's NOT in this repo (intentional, by project policy)

- Framework-specific node types or edge types (those live in
  `data-layer-adapters/<framework>/` if a framework needs them).
- Seed rows for any specific framework (postgres stores them; graph
  nodes derive from postgres state).
- Plugin code, MCP wiring, agent runtime glue (those are framework-
  adapter concerns, not graph-database concerns).
