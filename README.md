# data-layer-falkordb

Framework-agnostic FalkorDB graph service for the data-layer stack.

This project is parallel to `data-layer-postgres`: same identity
contract, same scope boundaries, same framework-agnostic posture.
Where postgres owns durable storage, falkordb adds traversal
(answers to questions like "which agents worked on this project?"
without multi-table joins).

## Layout

```
data-layer-falkordb/
├── .a0proj/                    Agent Zero project metadata
├── docs/
│   ├── graph-schema.md          node/edge schema and identity contract
│   └── decisions/               append-only ADRs
├── lib/
│   ├── falkordb.sh              falkordb server install (apt + systemd)
│   └── install.sh               applier (install | verify | status | reset)
├── migrations/                  Cypher migration files (in apply order)
│   ├── 0001_nodes.cypher        Project, Agent, Session, Message, Tool
│   └── 0002_edges.cypher        OWNS_AGENT, OWNS_SESSION, OWNS_TOOL, SENT_MESSAGE, RAN_TOOL
├── tests/smoke.sh               verify the graph is reachable
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Install falkordb server (apt + systemd)
sudo bash lib/falkordb.sh

# Apply all Cypher migrations (idempotent)
bash lib/install.sh install

# Verify all node + edge types are registered
bash lib/install.sh verify

# Show applied version + per-label counts
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_FALKORDB_URL` — bolt URI (default `bolt://localhost:7687`)
- `DATA_LAYER_FALKORDB_DATABASE` — graph name (default `default`)
- `DATA_LAYER_FALKORDB_PORT` — server port (default `7687`)

## Status

Greenfield scaffold. The `lib/install.sh` and `lib/falkordb.sh` scripts
follow the same patterns as `data-layer-postgres/lib/`. No live
falkordb server in this container — server install + apply requires
sudo and the falkordb binary.

## Boundary

This project does NOT own:

- Postgres schema → `../data-layer-postgres`
- Redis cache layer → `../data-layer-redis`
- Framework adapters → `../data-layer-adapters`
- Umbrella orchestration → `..`

## Installer URI + idempotency

`lib/falkordb.sh` downloads the FalkorDB binary from a release tarball
URI by default:

```
https://github.com/FalkorDB/FalkorDB/releases/download/v${DATA_LAYER_FALKORDB_VERSION}/falkordb-linux-x86_64.tar.gz
```

The installer is idempotent across three cases:

1. First run — no binary present: download + extract + `install -m 0755`.
2. Re-run — binary present with matching version: download skipped.
3. Version bump — binary present with old version: download + atomic overwrite.

Override the URI or version via env vars:

```bash
export DATA_LAYER_FALKORDB_VERSION=1.2.0
export DATA_LAYER_FALKORDB_TARBALL_URL=https://mirror.example/falkordb.tgz
sudo bash lib/falkordb.sh
```

See `docs/decisions/0001-falkordb-installer-uri-and-idempotency.md` for
the rationale.
