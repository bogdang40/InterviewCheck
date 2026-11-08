extension SessionDatabaseSchema {
    static let workspaceTables = """
        -- Job Workspaces: one folder per job pursuit plus its index
        CREATE TABLE IF NOT EXISTS job_workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            company TEXT NOT NULL DEFAULT '',
            role TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'researching',
            folder_path TEXT NOT NULL,
            folder_bookmark BLOB,
            job_description_summary TEXT,
            notes TEXT NOT NULL DEFAULT '',
            tags TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_opened_at INTEGER,
            is_archived INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS workspace_documents (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            category TEXT NOT NULL,
            byte_size INTEGER NOT NULL DEFAULT 0,
            sha256 TEXT NOT NULL,
            extracted_text TEXT,
            extracted_truncated INTEGER NOT NULL DEFAULT 0,
            indexed_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            UNIQUE(workspace_id, relative_path)
        );

        CREATE TABLE IF NOT EXISTS workspace_journal (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            session_id TEXT,
            thread_id TEXT,
            turn_id TEXT,
            created_at INTEGER NOT NULL
        );

        -- Personal knowledge graph: typed entities and relations
        CREATE TABLE IF NOT EXISTS kg_nodes (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            label TEXT NOT NULL,
            normalized_label TEXT NOT NULL,
            summary TEXT,
            properties TEXT,
            source_kind TEXT NOT NULL DEFAULT 'manual',
            source_ref TEXT,
            workspace_id TEXT,
            confidence REAL NOT NULL DEFAULT 1.0,
            mention_count INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(kind, normalized_label)
        );

        CREATE TABLE IF NOT EXISTS kg_edges (
            id TEXT PRIMARY KEY,
            from_node_id TEXT NOT NULL,
            to_node_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            evidence TEXT,
            source_ref TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(from_node_id, to_node_id, relation)
        );
        
        """
}
