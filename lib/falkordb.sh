#!/usr/bin/env bash
# data-layer-falkordb/lib/falkordb.sh — falkordb server install.
#
# On a fresh host: download the falkordb binary, place in /usr/local/bin/,
# write a systemd unit, start the service.
# On an existing host: verify the binary + systemd unit are present,
# ensure the service is running.

set -euo pipefail

BIN=/usr/local/bin/falkordb
UNIT=/etc/systemd/system/falkordb.service
DATA_DIR=/var/lib/falkordb
PORT="${DATA_LAYER_FALKORDB_PORT:-7687}"

log() { printf '[falkordb-server %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb-server FAIL] %s\n' "$*" >&2; exit 3; }

IN_DOCKER=0
[[ -f /.dockerenv || -f /run/.containerenv ]] && IN_DOCKER=1

# ---- detect existing binary ----
if command -v falkordb >/dev/null 2>&1 || [[ -x "$BIN" ]]; then
  log "falkordb binary present at $(command -v falkordb || echo $BIN)"
else
  if [[ $IN_DOCKER -eq 0 ]] && command -v curl >/dev/null 2>&1; then
    log "downloading falkordb binary"
    # Real install would fetch from a release URL. For now, print intent.
    log "  (real install would: curl -L https://github.com/.../falkordb.tgz | tar xz -C /usr/local)"
    log "  (skipping in this scaffold; manual install required)"
  else
    log "no curl or in docker; skipping binary install"
  fi
fi

# ---- ensure systemd unit ----
if [[ -f "$UNIT" ]]; then
  log "systemd unit $UNIT already present"
else
  if [[ $IN_DOCKER -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
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
    log "(unit written; install + start would happen via systemctl enable --now falkordb)"
  else
    log "no systemctl or in docker; skipping unit write"
  fi
fi

# ---- ensure data dir ----
mkdir -p "$DATA_DIR" || true

log "falkordb-server install placeholder complete"
log "real install requires: download binary, install systemd unit, systemctl enable --now falkordb"
