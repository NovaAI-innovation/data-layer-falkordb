# data-layer-falkordb

Framework-agnostic FalkorDB graph service for the data-layer stack.

This project owns the falkordb server install, graph bootstrap, node/edge
schema abstraction, and the graph-schema docs. It is wired into the
`data-layer` umbrella as a sibling submodule (its own git repository at
`github.com/NovaAI-innovation/data-layer-falkordb`).

## Layout

```
data-layer-falkordb/
├── .a0proj/                           Agent Zero project metadata
├── docs/
│   ├── graph-schema.md                 node/edge schema and identity rules
│   └── decisions/                     append-only ADRs
├── lib/
│   ├── falkordb.sh                    falkordb server install
│   └── install.sh                      applier (install | verify | status | reset)
├── tests/smoke.sh                     verify graph is reachable
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Install falkordb + start server
sudo bash lib/falkordb.sh

# Bootstrap the graph (create database + register node/edge types)
bash lib/install.sh install

# Verify graph is reachable + node/edge types registered
bash lib/install.sh verify

# Show node / edge counts
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_FALKORDB_URL` — bolt URI (default `bolt://localhost:7687`)
- `DATA_LAYER_FALKORDB_DATABASE` — graph name (default `default`)

## Status

Greenfield scaffold — no server install yet. `lib/falkordb.sh` is a
placeholder that prints intent; `lib/install.sh` validates reachability
via the bolt protocol and registers node/edge types on first install.
Production install requires the falkordb binary (out of agent scope).