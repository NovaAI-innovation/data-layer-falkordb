# AGENTS.md — data-layer-falkordb

Agent contract for the falkordb submodule of the data-layer stack.

## Scope and ownership

This project is the falkordb graph service. It owns the server install,
graph bootstrap, node/edge schema, and the graph-schema contract. It does
NOT own postgres, redis, the framework adapters, or the umbrella
orchestration. Those live in sibling projects.

## Isolation and security

Keep plans, scripts, configs, tests, docs, and evidence inside this
workspace. Do not write real secrets to source-controlled files; use
`.env.example` for placeholders. Do not modify files in `/a0`, the parent
`../data-layer/`, other sibling submodules, global plugins, system
services, or live databases unless the user explicitly requests the
integration and the side effect is reported.

## Required workflow

Before consequential changes, read `README.md`, `docs/graph-schema.md`,
`AGENTS.md`, `.a0proj/instructions/project-isolation.md`. State the
intended outcome and affected paths before implementation. Keep deployment
state separate from source.

## Runtime boundary

Use `/opt/venv-a0/bin/python` for Agent Zero framework and plugin-hook
checks. Use `/opt/venv/bin/python` for task or user-code checks. Do not
treat one runtime as proof of the other.

## Canonical references

- `lib/falkordb.sh` — falkordb server install
- `lib/install.sh` — applier (install | verify | status | reset)
- `docs/graph-schema.md` — node/edge schema and identity rules
- `docs/decisions/` — append-only ADRs