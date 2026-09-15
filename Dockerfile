# data-layer-falkordb/Dockerfile
#
# Builds the FalkorDB graph service for the data-layer stack.
# Wraps falkordb/falkordb:latest with:
#   - the two Cypher migration files (0001_nodes, 0002_edges)
#   - the python applier (bootstrap_payload.py) that splits multi-statement
#     Cypher on `;` and skips already-applied migrations
#     (idempotent via the _SchemaMigrations sentinel)
#   - a custom entrypoint that applies migrations + sample data on
#     first start, then forwards to the official falkordb server
#
# Build:   docker build -t data-layer-falkordb data-layer-falkordb/
#
# Run example:
#   docker run -d --name falkordb-test-sandbox \
#     -p 127.0.0.1:6379:6379 -p 127.0.0.1:7687:7687 -p 127.0.0.1:3000:3000 \
#     -v falkordb-data:/data \
#     data-layer-falkordb

FROM falkordb/falkordb:latest

LABEL org.opencontainers.image.title="data-layer-falkordb"
LABEL org.opencontainers.image.description="FalkorDB + data-layer migrations + sample seed"
LABEL org.opencontainers.image.source="data-layer/data-layer-falkordb"

# The base image ships redis-server + the falkordb.so module.
# We need python3 (for the bootstrap_payload.py applier and the
# healthcheck probe) and redis-tools (for redis-cli inside scripts).
# apt-get update and install must be in the same RUN — debian-slim
# requires update before install.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Ship migrations + applier.
COPY migrations/*.cypher          /opt/data-layer/migrations/
COPY lib/bootstrap_payload.py     /opt/data-layer/
COPY docker-entrypoint.sh         /usr/local/bin/data-layer-entrypoint
RUN chmod 0755 /usr/local/bin/data-layer-entrypoint

# Healthcheck via redis-cli PING on 6379. \\r\\n would be a RESP line
# terminator inside Python; with redis-cli we just send PING and check PONG.
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD redis-cli -p 6379 PING | grep -q PONG || exit 1

ENTRYPOINT ["/usr/local/bin/data-layer-entrypoint"]
CMD []
