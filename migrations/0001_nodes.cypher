-- 0001_nodes.cypher
--
-- Define the node types for the falkordb graph layer. Each node type
-- mirrors a table in data-layer-postgres, with the same id UUID.
--
-- Idempotent: constraints are applied with IF NOT EXISTS semantics via
-- the data-layer-falkordb/lib/install.sh applier.

-- Project nodes — one per postgres projects row.
CREATE NODE TABLE IF NOT EXISTS Project (
    id            STRING  PRIMARY KEY,
    project_key   STRING,
    display_name  STRING,
    status        STRING  DEFAULT 'active',
    created_at    DATETIME DEFAULT now(),
    metadata      STRING  DEFAULT '{}'
);

-- Agent nodes — one per postgres agents row.
-- Identity contract: (framework_id, framework_local_id, deployment)
-- is captured in the framework_local_id + deployment properties.
CREATE NODE TABLE IF NOT EXISTS Agent (
    id                  STRING  PRIMARY KEY,
    project_id          STRING,
    framework_id        STRING,
    framework_local_id  STRING,
    deployment          STRING  DEFAULT '',
    display_name        STRING,
    profile_key         STRING,
    status              STRING  DEFAULT 'active',
    created_at          DATETIME DEFAULT now(),
    metadata            STRING  DEFAULT '{}'
);

-- Session nodes — one per postgres sessions row.
CREATE NODE TABLE IF NOT EXISTS Session (
    id           STRING  PRIMARY KEY,
    agent_id     STRING,
    session_key  STRING,
    status       STRING  DEFAULT 'active',
    started_at   DATETIME DEFAULT now(),
    ended_at     DATETIME,
    metadata     STRING  DEFAULT '{}'
);

-- Message nodes — one per postgres messages row.
-- Direction (in/out) and role (user/assistant/tool/system) capture
-- the same shape as the postgres messages table.
CREATE NODE TABLE IF NOT EXISTS Message (
    id               STRING  PRIMARY KEY,
    session_id       STRING,
    agent_id         STRING,
    direction        STRING,
    role             STRING,
    peer_agent_id    STRING,
    content          STRING,
    content_type     STRING  DEFAULT 'text',
    thread_id        STRING,
    parent_message_id STRING,
    created_at       DATETIME DEFAULT now(),
    external_ref     STRING  DEFAULT '{}'
);

-- Tool nodes — one per postgres available_tools row.
CREATE NODE TABLE IF NOT EXISTS Tool (
    id         STRING  PRIMARY KEY,
    agent_id   STRING,
    tool_key   STRING,
    category   STRING,
    version    STRING,
    manifest   STRING  DEFAULT '{}',
    granted_at DATETIME DEFAULT now(),
    revoked_at DATETIME,
    metadata   STRING  DEFAULT '{}'
);
