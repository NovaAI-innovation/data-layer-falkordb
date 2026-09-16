#!/usr/bin/env bash
# data-layer-falkordb/lib/docker_image_install.sh
#
# Pull the falkordb binary out of the official Docker image via the
# registry HTTP API. No docker daemon required. The latest release
# only ships Docker images, not Linux tarballs, so the lib/falkordb.sh
# URL approach 404s.
#
# What gets installed:
#   /var/lib/falkordb/bin/falkordb.so  (the actual binary, ~50MB)
#   /var/lib/falkordb/bin/run.sh      (the canonical entrypoint)
#   /var/lib/falkordb/bin/gen-certs.sh (TLS helper)
#   /usr/local/bin/falkordb            (run.sh installed as the wrapper)
#
# After this script installs the binary, start it via:
#   redis-server --loadmodule /var/lib/falkordb/bin/falkordb.so \n#     --port 6389 --dir /var/lib/falkordb/data
# (or just `nohup /usr/local/bin/falkordb <args>` which execs that).
#
# FalkorDB rides ON TOP of redis-server as a loadable module. It is
# NOT a standalone binary. The image's run.sh wraps the redis-server
# invocation with --loadmodule falkordb.so + the FALKORDB_ARGS env.
#
# Requires: bash, curl, python3 (or just python), tar. No docker.
set -euo pipefail

REPO="${DATA_LAYER_FALKORDB_IMAGE_REPO:-falkordb/falkordb}"
TAG="${DATA_LAYER_FALKORDB_IMAGE_TAG:-latest}"
INSTALL_BIN_DIR="${DATA_LAYER_FALKORDB_BIN_DIR:-/var/lib/falkordb/bin}"
INSTALL_WRAPPER="${DATA_LAYER_FALKORDB_WRAPPER:-/usr/local/bin/falkordb}"
DATA_DIR="${DATA_LAYER_FALKORDB_DATA_DIR:-/var/lib/falkordb/data}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '[falkordb.install %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[falkordb.install FAIL] %s\n' "$*" >&2; exit 3; }

command -v curl >/dev/null 2>&1 || fail "curl required"
command -v tar  >/dev/null 2>&1 || fail "tar required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

log "fetching anonymous docker registry token for ${REPO}"
TOKEN=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" \n  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
[[ -n "$TOKEN" ]] || fail "failed to acquire docker registry token"

log "fetching manifest list for ${REPO}:${TAG}"
curl -fsSL -H "Authorization: Bearer $TOKEN" \n  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \n  "https://registry-1.docker.io/v2/${REPO}/manifests/${TAG}" \n  -o "$WORK/manifest_list.json"

DIGEST=$(python3 -c "
import json
m = json.load(open('${WORK}/manifest_list.json'))
for x in m.get('manifests', []):
    p = x.get('platform', {})
    if p.get('os') == 'linux' and p.get('architecture') == 'amd64':
        print(x['digest']); break
")
[[ -n "$DIGEST" ]] || fail "no linux/amd64 entry in manifest list"
log "platform manifest digest: ${DIGEST:0:24}..."

curl -fsSL -H "Authorization: Bearer $TOKEN" \n  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \n  "https://registry-1.docker.io/v2/${REPO}/manifests/${DIGEST}" \n  -o "$WORK/platform.json"

mapfile -t LAYERS < <(python3 -c "
import json
m = json.load(open('${WORK}/platform.json'))
for L in m.get('layers', []):
    print(L['digest'])
")

log "found ${#LAYERS[@]} layers; downloading + scanning for falkordb binary"
FOUND=0
for L in "${LAYERS[@]}"; do
  curl -fsSL -H "Authorization: Bearer $TOKEN" \n    "https://registry-1.docker.io/v2/${REPO}/blobs/${L}" \n    -o "$WORK/layer.tar.gz"
  # The image stores the binary as /var/lib/falkordb/bin/falkordb.so
  if tar -tzf "$WORK/layer.tar.gz" 2>/dev/null | grep -q '^var/lib/falkordb/bin/falkordb.so$'; then
    log "  HIT layer ${L:0:24}: contains /var/lib/falkordb/bin/falkordb.so"
    mkdir -p "$INSTALL_BIN_DIR"
    tar -xzf "$WORK/layer.tar.gz" -C / --no-same-owner 2>&1 | tail -2
    chmod 0755 "${INSTALL_BIN_DIR}/falkordb.so"
    FOUND=1
    break
  fi
done
[[ "$FOUND" -eq 1 ]] || fail "falkordb binary not found in any layer (image layout may have changed)"

# Re-scan to find the entrypoint scripts (run.sh + gen-certs.sh) in
# separate (small) layers. Same loop pattern.
for L in "${LAYERS[@]}"; do
  curl -fsSL -H "Authorization: Bearer $TOKEN" \n    "https://registry-1.docker.io/v2/${REPO}/blobs/${L}" \n    -o "$WORK/layer.tar.gz"
  for script in run.sh gen-certs.sh; do
    if tar -tzf "$WORK/layer.tar.gz" 2>/dev/null | grep -q "^var/lib/falkordb/bin/${script}$"; then
      tar -xzf "$WORK/layer.tar.gz" -C / --no-same-owner \n        "var/lib/falkordb/bin/${script}" 2>/dev/null || true
      chmod 0755 "${INSTALL_BIN_DIR}/${script}"
    fi
  done
done

# Install run.sh as the /usr/local/bin/falkordb wrapper (exec
# redis-server with --loadmodule falkordb.so + FALKORDB_ARGS env).
if [[ -f "${INSTALL_BIN_DIR}/run.sh" ]]; then
  install -m 0755 "${INSTALL_BIN_DIR}/run.sh" "${INSTALL_WRAPPER}"
fi

mkdir -p "$DATA_DIR"

log "installed:"
log "  module:   ${INSTALL_BIN_DIR}/falkordb.so"
ls -la "${INSTALL_BIN_DIR}/falkordb.so"
log "  wrapper:  ${INSTALL_WRAPPER}"
ls -la "${INSTALL_WRAPPER}"
log "  scripts:  ${INSTALL_BIN_DIR}/run.sh  ${INSTALL_BIN_DIR}/gen-certs.sh"
log "  data dir: ${DATA_DIR}"
log "next step:"
log "  redis-server --loadmodule ${INSTALL_BIN_DIR}/falkordb.so --port 6389 --dir ${DATA_DIR}"