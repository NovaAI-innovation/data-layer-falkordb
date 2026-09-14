#!/usr/bin/env bash
# data-layer-falkordb/tests/smoke.sh — verify graph is reachable.
# Runs lib/install.sh verify; non-zero on failure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
exec "$ROOT/lib/install.sh" verify
