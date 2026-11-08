import Foundation

extension SessionDatabaseMigrationSteps {
    static let practiceAndWorkspaces: [MigrationStep] = [
        MigrationStep(
            version: 12,
            statements: [
                """
                CREATE TABLE IF NOT EXISTS session_mode_snapshots (
                    snapshot_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL UNIQUE,
                    source_mode_id TEXT,
                    captured_at INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    prompt_text TEXT NOT NULL,
                    attachments_json TEXT NOT NULL,
                    project_folder_display_path TEXT,
                    project_folder_enabled_at_capture INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_summaries (
                    session_id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    background_summary TEXT NOT NULL DEFAULT '',
                    follow_up_email TEXT,
                    generated_at INTEGER,
                    error_message TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_summary_action_items (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    owner TEXT,
                    due_date TEXT,
                    notes TEXT,
                    ordinal INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES session_summaries(session_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_tool_calls (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    thread_id TEXT,
                    turn_id TEXT,
                    tool_name TEXT NOT NULL,
                    arguments_json TEXT NOT NULL,
                    result_preview TEXT,
                    is_error INTEGER NOT NULL DEFAULT 0,
                    iteration INTEGER NOT NULL DEFAULT 0,
                    started_at INTEGER NOT NULL,
                    duration_ms INTEGER,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_session_mode_snapshots_session ON session_mode_snapshots(session_id)",
                "CREATE INDEX IF NOT EXISTS idx_session_summary_ai_session ON session_summary_action_items(session_id, ordinal)",
                "CREATE INDEX IF NOT EXISTS idx_session_tool_calls_session ON session_tool_calls(session_id, started_at)",
                "CREATE INDEX IF NOT EXISTS idx_session_tool_calls_turn ON session_tool_calls(turn_id)"
            ]
        ),
        MigrationStep(
            version: 13,
            statements: [
                "ALTER TABLE session_tool_calls ADD COLUMN display_input TEXT",
                "ALTER TABLE session_tool_calls ADD COLUMN result_content TEXT",
                "ALTER TABLE session_tool_calls ADD COLUMN content_truncated INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE session_tool_calls ADD COLUMN overflow_path TEXT"
            ],
            backfills: [
                """
                UPDATE session_tool_calls
                SET display_input = arguments_json
                WHERE display_input IS NULL OR TRIM(display_input) = '';
                """,
                """
                UPDATE session_tool_calls
                SET result_content = result_preview
                WHERE result_content IS NULL AND result_preview IS NOT NULL;
                """
            ]
        ),
        MigrationStep(
            version: 14,
            statements: [
                """
                CREATE TABLE IF NOT EXISTS practice_cards (
                    id TEXT PRIMARY KEY,
                    created_at INTEGER NOT NULL,
                    session_id TEXT NOT NULL,
                    topic_tag TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    ideal_reasoning TEXT NOT NULL,
                    transcript_snippet TEXT NOT NULL,
                    candidate_attempt_summary TEXT NOT NULL,
                    difficulty TEXT NOT NULL,
                    evidence_kind TEXT NOT NULL,
                    evidence_value TEXT,
                    is_archived INTEGER NOT NULL DEFAULT 0
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS practice_schedules (
                    card_id TEXT PRIMARY KEY,
                    repetition_count INTEGER NOT NULL,
                    easiness REAL NOT NULL,
                    interval_days INTEGER NOT NULL,
                    next_review_at INTEGER NOT NULL,
                    lapses INTEGER NOT NULL,
                    last_reviewed_at INTEGER,
                    FOREIGN KEY (card_id) REFERENCES practice_cards(id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS practice_reviews (
                    id TEXT PRIMARY KEY,
                    card_id TEXT NOT NULL,
                    reviewed_at INTEGER NOT NULL,
                    grade INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL DEFAULT 0,
                    self_reported_confidence INTEGER,
                    feedback TEXT,
                    attempt_transcript TEXT,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (card_id) REFERENCES practice_cards(id)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_practice_cards_session ON practice_cards(session_id, created_at)",
                "CREATE INDEX IF NOT EXISTS idx_practice_schedules_due ON practice_schedules(next_review_at)",
                "CREATE INDEX IF NOT EXISTS idx_practice_reviews_card ON practice_reviews(card_id, reviewed_at)"
            ]
        ),
        MigrationStep(
            version: 15,
            statements: [
                // getRecentQuickAssistCalls orders the widest table by
                // started_at with no filter: without this index every call is
                // a full scan plus sort.
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_calls_started_at ON quick_assist_calls(started_at)",
                // Timeline reads filter by session and order by timestamp.
                "CREATE INDEX IF NOT EXISTS idx_transcript_entries_session_ts ON transcript_entries(session_id, timestamp)"
            ]
        ),
        MigrationStep(
            version: 16,
            statements: [
                // Job Workspaces + personal knowledge graph. The FTS mirror for
                // kg_nodes is created best effort in createTables, never here,
                // so a SQLite build without FTS5 cannot stall the ladder.
                """
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
                )
                """,
                """
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
                )
                """,
                """
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
                )
                """,
                """
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
                )
                """,
                """
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
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_job_workspaces_updated_at ON job_workspaces(is_archived, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_workspace_documents_workspace ON workspace_documents(workspace_id, category)",
                "CREATE INDEX IF NOT EXISTS idx_workspace_journal_workspace ON workspace_journal(workspace_id, created_at)",
                "CREATE INDEX IF NOT EXISTS idx_kg_nodes_kind_updated ON kg_nodes(kind, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_kg_nodes_workspace ON kg_nodes(workspace_id)",
                "CREATE INDEX IF NOT EXISTS idx_kg_edges_from ON kg_edges(from_node_id)",
                "CREATE INDEX IF NOT EXISTS idx_kg_edges_to ON kg_edges(to_node_id)"
            ]
        )
    ]
}
