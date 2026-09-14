# FalkorDB graph schema

The falkordb layer is the cross-component graph store for relationship
queries (entity → entity → edge → relation). It is framework-agnostic:
no Agent Zero specifics, no Agent Zero plugin code.

## Database

One database per data-layer deployment, named by `$DATA_LAYER_FALKORDB_DATABASE`
(default `default`). Created on first install.

## Node types

The graph stores nodes for the same entities the postgres layer tracks,
but as a flat graph for traversal queries:

| Label | Mirrors | Identity field |
|---|---|---|
| `Project` | `projects.id` | `project_id` |
| `Agent` | `agents.id` | `agent_id` |
| `Session` | `sessions.id` | `session_id` |
| `Tool` | `available_tools.id` | `tool_id` |

## Edge types

| Type | From → To | Properties |
|---|---|---|
| `OWNS_AGENT` | Project → Agent | `created_at` |
| `OWNS_SESSION` | Agent → Session | `created_at` |
| `OWNS_TOOL` | Agent → Tool | `granted_at` |
| `SENT_MESSAGE` | Session → Session | `message_id`, `direction` |
| `RAN_TOOL` | Session → Tool | `tool_execution_id`, `started_at` |

## Identity contract

Node `id` values are UUIDs identical to the postgres `id` columns, so a
graph traversal can join to the postgres layer for full-fidelity reads.

## Failure semantics

- **Connection refused** → install/verify/status report a structured failure
  but never corrupt state.
- **Write conflict** (constraint violation on uniqueness) → returns the
  existing node instead of overwriting.
