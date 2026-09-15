#!/usr/bin/env bash
# data-layer-falkordb/lib/falkordb.sh — falkordb server install.
#
# Idempotent installation of the falkordb server. Reads the release
# version from DATA_LAYER_FALKORDB_VERSION (default '1.2.0') and
# downloads a pre-built Linux tarball from the FalkorDB GitHub release
# if the local binary is missing or out-of-date. Subsequent runs
# detect the existing binary's version and skip the download.
#
# URI template: https://github.com/FalkorDB/FalkorDB/releases/download/v${VERSION}/falkordb-linux-x86_64.tar.gz
#
# Override the URL template via DATA_LAYER_FALKORDB_TARBALL_URL for
# self-hosted mirrors or alternative release channels.

set -euo pipefail

BIN_DIR=/usr/local/bin
BIN="$BIN_DIR/falkordb"
UNIT=/etc/systemd/system/falkordb.service
DATA_DIR=/var/lib/falkordb
PORT="${DATA_LAYER_FALKORDB_PORT:-7687}"
VERSION="${DATA_LAYER_FALKORDB_VERSION:-1.2.0}"
TARBALL_URL="${DATA_LAYER_FALKORDB_TARBALL_URL:-https://github.com/FalkorDB/FalkorDB/releases/download/v${VERSION}/falkordb-linux-x86_64.tar.gz}"

log()  { printf '[falkordb-server %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb-server FAIL] %s\n' "$*" >&2; exit 3; }

IN_DOCKER=0
[[ -f /.dockerenv || -f /run/.containerenv ]] && IN_DOCKER=1

# ---- detect existing version (idempotency check) ----
detected_version=""
if [[ -x "$BIN" ]]; then
  # The falkordb server supports `--version` (or `falkordb --version`).
  detected_version="$("$BIN" --version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
fi
needs_install=0
if [[ ! -x "$BIN" ]]; then
  needs_install=1
  log "no falkordb binary at $BIN"
elif [[ -n "$detected_version" && "$detected_version" != "v$VERSION" && "$detected_version" != "$VERSION" ]]; then
  needs_install=1
  log "installed falkordb is $detected_version, expected v$VERSION"
elif [[ -n "$detected_version" ]]; then
  log "falkordb $detected_version already installed (matches v$VERSION); skipping download"
fi

# ---- install if needed ----
if [[ $needs_install -eq 1 ]]; then
  if [[ $IN_DOCKER -eq 0 ]] && command -v curl >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    trap "rm -rf '$TMP'" EXIT
    log "downloading $TARBALL_URL"
    if curl -fsSL --fail-with-body -o "$TMP/falkordb.tgz" "$TARBALL_URL" 2>&1 | tail -3; then
      tar -xzf "$TMP/falkordb.tgz" -C "$TMP"
      # The tarball layout may put the binary at the root or under bin/.
      if [[ -x "$TMP/falkordb" ]]; then
        install -m 0755 "$TMP/falkordb" "$BIN"
      elif [[ -x "$TMP/bin/falkordb" ]]; then
        install -m 0755 "$TMP/bin/falkordb" "$BIN"
      else
        fail "could not locate falkordb binary inside downloaded archive"
      fi
      log "installed falkordb to $BIN"
    else
      log "(download failed; manually install falkordb v$VERSION or override DATA_LAYER_FALKORDB_TARBALL_URL)"
      log "(falling back to apt or source build for this scaffold)"
    fi
  else
    log "(no curl or in docker; manually install falkordb v$VERSION)"
  fi
fi

# ---- ensure systemd unit (idempotent: not overwritten if present) ----
if [[ -f "$UNIT" ]]; then
  log "systemd unit $UNIT already present; not overwriting"
elif [[ $IN_DOCKER -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
  log "writing systemd unit $UNIT"
  cat > "$UNIT" <<UNIT
[Unit]
Description=FalkorDB graph database
After=network.target

[Service]
Type=simple
User=falkordb
ExecStart=$BIN --port $PORT --data-dir $DATA_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  log "unit written; systemctl enable --now falkordb to start"
else
  log "(no systemctl or in docker; skipping unit write; manual systemd setup needed)"
fi

# ---- ensure data dir ----
mkdir -p "$DATA_DIR" || true

echo ""
log "falkordb-server install phase complete"
log "  binary:       $BIN"
log "  detected:     $detected_version  (expected v$VERSION)"
log "  systemd:      $UNIT"
log "  data dir:     $DATA_DIR"
log "  port:         $PORT"
log "  tarball url:  $TARBALL_URL"
