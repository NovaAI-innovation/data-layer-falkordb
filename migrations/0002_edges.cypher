-- 0002_edges.cypher
--
-- Define the edge types for the falkordb graph layer. Each edge captures
-- a relationship that would otherwise be a FK or a derived join in postgres.
-- The graph layer's job is traversal; the postgres layer's job is
-- authoritative storage.

-- Project owns its agents.
CREATE EDGE TABLE IF NOT EXISTS OWNS_AGENT(
    created_at DATETIME DEFAULT now()
);

-- Agent owns its sessions.
CREATE EDGE TABLE IF NOT EXISTS OWNS_SESSION(
    created_at DATETIME DEFAULT now()
);

-- Agent owns its tool grants.
CREATE EDGE TABLE IF NOT EXISTS OWNS_TOOL(
    granted_at DATETIME DEFAULT now()
);

-- Session sent messages (self-edge for threading — a session can send
-- to itself for a self-message).
CREATE EDGE TABLE IF NOT EXISTS SENT_MESSAGE(
    message_id   STRING,
    sent_at      DATETIME DEFAULT now()
);

-- Session ran a tool execution.
CREATE EDGE TABLE IF NOT EXISTS RAN_TOOL(
    tool_execution_id STRING,
    started_at         DATETIME DEFAULT now()
);
