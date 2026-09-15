# Decision 0001 — falkordb installer URI + idempotency strategy

## Context

`data-layer-falkordb/lib/falkordb.sh` needs to download and install the
falkordb server. The binary must be the canonical release tarball from
the FalkorDB GitHub release page. Idempotency must hold across:

- Re-runs of `bootstrap` (no redundant download if binary is present).
- Version bumps (changing `DATA_LAYER_FALKORDB_VERSION` triggers a
  fresh download and overwrites the old binary).
- Operator override (`DATA_LAYER_FALKORDB_TARBALL_URL` lets the
  operator point at a self-hosted mirror).

## Decision

The installer reads:

- `DATA_LAYER_FALKORDB_VERSION` (default `1.2.0`).
- `DATA_LAYER_FALKORDB_TARBALL_URL` (default
  `https://github.com/FalkorDB/FalkorDB/releases/download/v${VERSION}/falkordb-linux-x86_64.tar.gz`).

It detects the local binary's version via `falkordb --version`. If the
detected version matches `v${VERSION}` (or the bare version string),
it skips the download. If missing or mismatched, it fetches the
tarball, extracts the binary, and `install -m 0755` overwrites the
existing binary at `/usr/local/bin/falkordb`.

The systemd unit is written only if missing (`if [[ -f $UNIT ]]; then
log "already present"`). Subsequent runs don't touch it.

## Why this works

- The detect + match loop is the idempotency surface. Re-runs with
  unchanged env see `detected_version == v${VERSION}` and skip
  download entirely. No checksum, no lockfile needed.
- Version bumps trigger a single fetch + atomic overwrite via
  `install`. No multi-step state to keep in sync.
- The systemd unit is `if ! exists; write; fi`. Operators can edit
  the unit file in place; the installer doesn't clobber.
- Operator can self-host by exporting `DATA_LAYER_FALKORDB_TARBALL_URL`
  to a mirror; the version-detection logic still gates upgrades.

## What we deliberately didn't do

- No checksum verification. The release tarball is fetched over
  HTTPS; if integrity matters more than availability, set
  `DATA_LAYER_FALKORDB_TARBALL_SHA256` and add a sha256sum check.
- No apt path. FalkorDB doesn't ship .deb packages; release
  tarballs are the canonical distribution.
- No automatic source build. If the release tarball is unavailable,
  the installer prints a fallback hint and exits non-fatal. Operator
  builds from source if needed.

## When to revisit

- When FalkorDB ships official Linux packages (.deb / .rpm).
- When the install needs to be reproducible in CI (pin a specific
  release tag in `DATA_LAYER_FALKORDB_VERSION` per-environment).
- When sandboxed environments (no systemd) become primary targets.
