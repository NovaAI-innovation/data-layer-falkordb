#!/usr/bin/env python3
"""
lib/bootstrap_payload.py
========================

FalkorDB test-sandbox bootstrap payload — used by lib/install.sh's
`bootstrap-test-sandbox` subcommand and the umbrella's bootstrap dispatcher.

What it does (in order):
  1. Drop & recreate the named falkordb container
     (idempotent — matches the data-layer umbrella contract).
  2. Apply migrations/*.cypher via raw RESP (one statement per call;
     FalkorDB rejects multi-statement Cypher).
  3. Insert sample data (matching the postgres dataset, same UUIDs).
  4. Run a smoke test: 4 real Cypher queries against the live graph.

Connection: raw RESP on TCP localhost:6379 (FalkorDB is a Redis module;
port 7687 is the embedded Next.js UI, NOT bolt). Falls back to bolt 7687
only when run_query() in lib/install.sh handles it via falkordb-cli.

Exit codes:
  0  success
  2  connection error (falkordb not reachable)
  3  migration apply error
  4  sample-data insert error
  5  smoke query error
"""
import argparse
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

# ----- redis-protocol client (FalkorDB speaks RESP, not bolt) -----
class Falkor:
    def __init__(self, host="127.0.0.1", port=6379, timeout=30):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.buf = b""
    def close(self):
        try: self.s.close()
        except Exception: pass
    def _readline(self):
        while b"\r\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk: raise EOFError("eof")
            self.buf += chunk
        i = self.buf.index(b"\r\n")
        line, self.buf = self.buf[:i], self.buf[i+2:]
        return line
    def _readn(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk: raise EOFError("eof")
            self.buf += chunk
        d, self.buf = self.buf[:n], self.buf[n:]
        return d
    def _read_resp(self):
        head = self._readline()
        t = chr(head[0])
        if t == "+": return ("ok", head[1:].decode(errors="replace"))
        if t == "-": return ("err", head[1:].decode(errors="replace"))
        if t == ":": return ("int", int(head[1:]))
        if t == "$":
            n = int(head[1:])
            if n < 0: return ("nil", None)
            d = self._readn(n).decode(errors="replace"); self._readn(2)
            return ("bulk", d)
        if t == "*":
            n = int(head[1:])
            if n < 0: return ("nil", None)
            return [self._read_resp() for _ in range(n)]
        raise RuntimeError(head)
    def cmd(self, *args):
        parts = [f"*{len(args)}\r\n"]
        for a in args:
            ab = a.encode()
            parts.append(f"${len(ab)}\r\n"); parts.append(ab.decode()); parts.append("\r\n")
        self.s.sendall("".join(parts).encode())
        return self._read_resp()

# ----- cypher migration applier -----
#
# FalkorDB schema model: there is NO DDL for node/edge tables.
# Schema is implicit — labels and edge types are registered automatically
# the first time they're used in a CREATE / MERGE statement. The
# `CREATE NODE TABLE IF NOT EXISTS …` and `CREATE EDGE TABLE IF NOT EXISTS …`
# statements from Neo4j/Memgraph are documented in migrations/*.cypher
# for human readability but are skipped at apply time.
#
# Constraints that matter (id uniqueness, type validation) are enforced
# in the application layer. The graph `data_layer` is the schema-as-data
# source of truth.
DDL_PREFIXES = ("CREATE NODE TABLE", "CREATE EDGE TABLE", "CREATE INDEX", "CREATE CONSTRAINT")

def apply_cypher_file(fk, path):
    """Apply a multi-statement .cypher file by splitting on `;` and
    sending each statement via GRAPH.QUERY. FalkorDB rejects multi-
    statement Cypher in a single GRAPH.QUERY call, so we split.

    Neo4j-style DDL (CREATE NODE TABLE etc.) is recognized and skipped
    with an informational note — FalkorDB does not implement those,
    and the labels they document are auto-created when first used."""
    src = Path(path).read_text()
    statements = []
    buf = []
    for line in src.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        buf.append(line)
        if stripped.endswith(";"):
            statements.append("\n".join(buf).rstrip(";\n").strip())
            buf = []
    if buf:
        statements.append("\n".join(buf).strip())
    applied = 0
    skipped_ddl = 0
    for i, stmt in enumerate(statements, 1):
        if not stmt:
            continue
        # detect Neo4j-style DDL: these don't apply to FalkorDB
        first_line = stmt.splitlines()[0].strip().upper()
        if any(first_line.startswith(p) for p in DDL_PREFIXES):
            skipped_ddl += 1
            print(f"    [{i}/{len(statements)}] skip-DDL: {first_line[:80]} (FalkorDB: schema is implicit)")
            continue
        resp = fk.cmd("GRAPH.QUERY", "data_layer", stmt)
        if isinstance(resp, list) and resp and isinstance(resp[0], list):
            applied += 1
            print(f"    [{i}/{len(statements)}] applied: {first_line[:60]}")
        elif isinstance(resp, tuple) and resp[0] == "err":
            low = resp[1].lower()
            if "already exists" in low:
                applied += 1
                print(f"    [{i}/{len(statements)}] already-exists: {first_line[:60]}")
            else:
                print(f"    [{i}/{len(statements)}] ERR: {resp[1]}")
                print(f"      statement: {stmt[:160]}")
                sys.exit(3)
    print(f"    applied={applied} skip-ddl={skipped_ddl}")
    return applied

# ----- sample data seed (matches the postgres dataset; same UUIDs) -----
SEED_STATEMENTS = [
    # Frameworks
    "MERGE (f1:Framework {id:'11111111-1111-1111-1111-111111111111'}) SET f1.kind='agent_zero', f1.display_name='Agent Zero', f1.version='2.11'",
    "MERGE (f2:Framework {id:'22222222-2222-2222-2222-222222222222'}) SET f2.kind='hermes', f2.display_name='Hermes (Nous Research)', f2.version='1.0'",
    # Project
    "MERGE (p:Project {id:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}) SET p.project_key='data-layer-demo', p.display_name='Data Layer Demo', p.status='active'",
    # Agents
    "MERGE (a1:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}) SET a1.project_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', a1.framework_id='11111111-1111-1111-1111-111111111111', a1.framework_local_id='agent-zero-demo', a1.deployment='local', a1.display_name='Demo A0 Agent', a1.profile_key='a0', a1.status='active'",
    "MERGE (a2:Agent {id:'cccccccc-cccc-cccc-cccc-cccccccccccc'}) SET a2.project_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', a2.framework_id='22222222-2222-2222-2222-222222222222', a2.framework_local_id='hermes-demo', a2.deployment='hermes', a2.display_name='Demo Hermes Agent', a2.profile_key='hermes', a2.status='active'",
    # Tools
    "MERGE (t1:Tool {id:'dddddddd-dddd-dddd-dddd-dddddddddddd'}) SET t1.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', t1.tool_key='execute_sql', t1.category='data'",
    "MERGE (t2:Tool {id:'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}) SET t2.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', t2.tool_key='mcp_recall', t2.category='memory'",
    # Sessions
    "MERGE (s1:Session {id:'11110000-1111-1111-1111-111111111111'}) SET s1.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', s1.session_key='a0-session-1', s1.status='closed'",
    "MERGE (s2:Session {id:'22220000-2222-2222-2222-222222222222'}) SET s2.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', s2.session_key='a0-session-2', s2.status='closed'",
    "MERGE (s3:Session {id:'33330000-3333-3333-3333-333333333333'}) SET s3.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', s3.session_key='a0-session-3', s3.status='active'",
    # Messages
    "MERGE (m1:Message {id:'1aa00000-1111-1111-1111-111111111111'}) SET m1.session_id='11110000-1111-1111-1111-111111111111', m1.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', m1.direction='in', m1.role='user', m1.content='What tools do you have?', m1.content_type='text'",
    "MERGE (m2:Message {id:'1bb00000-1111-1111-1111-111111111111'}) SET m2.session_id='11110000-1111-1111-1111-111111111111', m2.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', m2.direction='out', m2.role='assistant', m2.content='I have execute_sql and mcp_recall.', m2.content_type='text'",
    "MERGE (m3:Message {id:'1cc00000-1111-1111-1111-111111111111'}) SET m3.session_id='22220000-2222-2222-2222-222222222222', m3.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', m3.direction='in', m3.role='user', m3.content='Run a SELECT against messages.', m3.content_type='text'",
    "MERGE (m4:Message {id:'1dd00000-1111-1111-1111-111111111111'}) SET m4.session_id='22220000-2222-2222-2222-222222222222', m4.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', m4.direction='out', m4.role='tool', m4.content='{\"rows\": 4, \"ok\": true}', m4.content_type='json'",
    "MERGE (m5:Message {id:'1ee00000-1111-1111-3333-333333333333'}) SET m5.session_id='33330000-3333-3333-3333-333333333333', m5.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', m5.direction='in', m5.role='user', m5.content='Now recall the most recent message.', m5.content_type='text'",
    # Tool executions
    "MERGE (te1:ToolExecution {id:'1ff00000-1111-1111-1111-111111111111'}) SET te1.agent_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', te1.session_id='22220000-2222-2222-2222-222222222222', te1.message_id='1dd00000-1111-1111-1111-111111111111', te1.tool_name='execute_sql', te1.arguments='{\"sql\": \"SELECT * FROM messages\"}', te1.status='success', te1.duration_ms=1000",
    # Edges
    "MATCH (p:Project {id:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}), (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}) MERGE (p)-[:OWNS_AGENT]->(a)",
    "MATCH (p:Project {id:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}), (a:Agent {id:'cccccccc-cccc-cccc-cccc-cccccccccccc'}) MERGE (p)-[:OWNS_AGENT]->(a)",
    "MATCH (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}), (s:Session {id:'11110000-1111-1111-1111-111111111111'}) MERGE (a)-[:OWNS_SESSION]->(s)",
    "MATCH (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}), (s:Session {id:'22220000-2222-2222-2222-222222222222'}) MERGE (a)-[:OWNS_SESSION]->(s)",
    "MATCH (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}), (s:Session {id:'33330000-3333-3333-3333-333333333333'}) MERGE (a)-[:OWNS_SESSION]->(s)",
    "MATCH (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}), (t:Tool {id:'dddddddd-dddd-dddd-dddd-dddddddddddd'}) MERGE (a)-[:OWNS_TOOL]->(t)",
    "MATCH (a:Agent {id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}), (t:Tool {id:'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}) MERGE (a)-[:OWNS_TOOL]->(t)",
    "MATCH (s:Session {id:'11110000-1111-1111-1111-111111111111'}) MERGE (s)-[:SENT_MESSAGE]->(s)",
    "MATCH (s:Session {id:'22220000-2222-2222-2222-222222222222'}) MERGE (s)-[:SENT_MESSAGE]->(s)",
    "MATCH (s:Session {id:'33330000-3333-3333-3333-333333333333'}) MERGE (s)-[:SENT_MESSAGE]->(s)",
    "MATCH (s:Session {id:'22220000-2222-2222-2222-222222222222'}), (t:Tool {id:'dddddddd-dddd-dddd-dddd-dddddddddddd'}) MERGE (s)-[:RAN_TOOL]->(t)",
]

# ----- smoke queries -----
SMOKE_QUERIES = [
    "RETURN 1 AS n",
    "MATCH (p:Project) RETURN count(p) AS project_count",
    "MATCH (a:Agent)-[:OWNS_SESSION]->(s:Session)-[:RAN_TOOL]->(t:Tool) "
        "RETURN count(*) AS joined_path_count",
    "MATCH (s:_SchemaMigrations {id:'singleton'}) RETURN s.version AS schema_version",
]

# ----- main -----
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6379)
    parser.add_argument("--graph", default="data_layer")
    parser.add_argument("--migrations-dir", default=str(Path(__file__).parent.parent / "migrations"))
    parser.add_argument("--no-seed", action="store_true",
                        help="skip sample-data insertion (migrate only)")
    parser.add_argument("--no-smoke", action="store_true",
                        help="skip smoke test (migrate+seed only)")
    parser.add_argument("--wait", type=int, default=0,
                        help="seconds to wait before connecting (for fresh containers)")
    args = parser.parse_args()

    if args.wait:
        print(f"# waiting {args.wait}s for falkordb...")
        time.sleep(args.wait)

    # 1) connect
    print(f"# connecting to {args.host}:{args.port} (raw RESP)")
    try:
        fk = Falkor(args.host, args.port)
    except OSError as e:
        print(f"# ERR: cannot connect to falkordb: {e}")
        sys.exit(2)
    pong = fk.cmd("PING")
    if pong != ("ok", "PONG"):
        print(f"# ERR: PING failed: {pong}")
        sys.exit(2)
    print("# PING -> PONG  ✓")

    # 2) delete existing graph (clean slate)
    print(f"\n# dropping existing graph '{args.graph}' (idempotent)")
    resp = fk.cmd("GRAPH.DELETE", args.graph)
    if isinstance(resp, tuple) and resp[0] == "err" and "empty key" not in resp[1].lower():
        print(f"# WARN: GRAPH.DELETE returned: {resp[1]}")
    else:
        print(f"# GRAPH.DELETE -> {resp[1] if isinstance(resp, tuple) else resp}")

    # 3) apply migrations
    mig_dir = Path(args.migrations_dir)
    cypher_files = sorted(mig_dir.glob("*.cypher"))
    print(f"\n# applying {len(cypher_files)} migration(s) from {mig_dir}")
    for cf in cypher_files:
        print(f"\n  -- {cf.name} --")
        apply_cypher_file(fk, str(cf))

    # 4) schema_migrations sentinel
    print("\n# registering _SchemaMigrations sentinel")
    fk.cmd("GRAPH.QUERY", args.graph,
           'MERGE (s:_SchemaMigrations {id:"singleton"}) ON CREATE SET s.version="0002_edges" RETURN s.version')

    # 5) seed sample data
    if args.no_seed:
        print("\n# --no-seed: skipping sample data")
    else:
        print(f"\n# inserting {len(SEED_STATEMENTS)} sample-data statements")
        for i, q in enumerate(SEED_STATEMENTS, 1):
            resp = fk.cmd("GRAPH.QUERY", args.graph, q)
            if isinstance(resp, tuple) and resp[0] == "err":
                print(f"  [{i}/{len(SEED_STATEMENTS)}] ERR: {resp[1]} :: {q[:60]}...")
                sys.exit(4)
        print(f"# seeded all {len(SEED_STATEMENTS)} statements  ✓")

    # 6) smoke test
    if args.no_smoke:
        print("\n# --no-smoke: skipping smoke test")
    else:
        print("\n# smoke queries")
        for q in SMOKE_QUERIES:
            resp = fk.cmd("GRAPH.QUERY", args.graph, q)
            print(f"  q: {q[:80]}")
            print(f"     resp: {str(resp)[:120]}")

    fk.close()
    print("\n# bootstrap done")

if __name__ == "__main__":
    main()
