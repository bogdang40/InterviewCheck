import Foundation

extension SessionDatabaseMigrationSteps {
    static let quickAssistEvolution: [MigrationStep] = [
        MigrationStep(
            version: 2,
            statements: [
                // api_calls new columns
                "ALTER TABLE api_calls ADD COLUMN system_prompt TEXT",
                "ALTER TABLE api_calls ADD COLUMN request_payload TEXT",
                "ALTER TABLE api_calls ADD COLUMN response_payload TEXT",
                // quick_assist_calls new columns
                "ALTER TABLE quick_assist_calls ADD COLUMN transcript_text TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN question TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN extra_context TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN request_payload TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN response_text TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN previous_response TEXT"
            ]
        ),
        MigrationStep(
            version: 3,
            statements: [
                "CREATE TABLE IF NOT EXISTS quick_assist_threads (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, title TEXT, origin_session_id TEXT)",
                "ALTER TABLE quick_assist_calls ADD COLUMN thread_id TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN turn_id TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN context_mode TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN model_tier TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN question_source TEXT"
            ],
            backfills: [
                """
                UPDATE quick_assist_calls
                SET thread_id = session_id
                WHERE thread_id IS NULL OR TRIM(thread_id) = '';
                """,
                """
                UPDATE quick_assist_calls
                SET turn_id = lower(hex(randomblob(16)))
                WHERE turn_id IS NULL OR TRIM(turn_id) = '';
                """,
                """
                UPDATE quick_assist_calls
                SET context_mode = 'conversation'
                WHERE context_mode IS NULL OR TRIM(context_mode) = '';
                """,
                """
                UPDATE quick_assist_calls
                SET model_tier = 'fast'
                WHERE model_tier IS NULL OR TRIM(model_tier) = '';
                """,
                """
                UPDATE quick_assist_calls
                SET question_source = CASE
                    WHEN question IS NULL OR TRIM(question) = '' THEN 'none'
                    WHEN lower(question) LIKE 'based on my latest transcript and current screen,%' THEN 'auto'
                    ELSE 'manual'
                END
                WHERE question_source IS NULL OR TRIM(question_source) = '';
                """,
                """
                INSERT OR IGNORE INTO quick_assist_threads (id, created_at, updated_at, title, origin_session_id)
                SELECT
                    thread_id,
                    MIN(created_at),
                    MAX(created_at),
                    NULL,
                    MIN(session_id)
                FROM quick_assist_calls
                WHERE thread_id IS NOT NULL AND TRIM(thread_id) <> ''
                GROUP BY thread_id;
                """,
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_threads_updated_at ON quick_assist_threads(updated_at);",
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_id ON quick_assist_calls(thread_id);",
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_id_started_at ON quick_assist_calls(thread_id, started_at);"
            ]
        ),
        MigrationStep(
            version: 4,
            statements: [
                """
                CREATE TABLE IF NOT EXISTS memory_nodes (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    source_type TEXT NOT NULL,
                    source_ref TEXT,
                    content TEXT NOT NULL,
                    summary TEXT,
                    tags TEXT,
                    importance INTEGER DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS memory_relationships (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    from_node_id TEXT NOT NULL,
                    to_node_id TEXT NOT NULL,
                    relation_type TEXT NOT NULL,
                    strength INTEGER DEFAULT 1,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (from_node_id) REFERENCES memory_nodes(id),
                    FOREIGN KEY (to_node_id) REFERENCES memory_nodes(id)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_memory_nodes_session_id ON memory_nodes(session_id)",
                "CREATE INDEX IF NOT EXISTS idx_memory_nodes_source_type ON memory_nodes(source_type)",
                "CREATE INDEX IF NOT EXISTS idx_memory_nodes_updated_at ON memory_nodes(updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_memory_relationships_from ON memory_relationships(from_node_id)",
                "CREATE INDEX IF NOT EXISTS idx_memory_relationships_to ON memory_relationships(to_node_id)"
            ],
            postStep: { database in
                database.createMemoryFTSTableIfSupported()
            }
        ),
        MigrationStep(
            version: 5,
            statements: [
                "ALTER TABLE quick_assist_calls ADD COLUMN raw_response_text TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN guarded_response_text TEXT"
            ],
            backfills: [
                """
                UPDATE quick_assist_calls
                SET raw_response_text = response_text
                WHERE (raw_response_text IS NULL OR TRIM(raw_response_text) = '')
                  AND response_text IS NOT NULL;
                """,
                """
                UPDATE quick_assist_calls
                SET guarded_response_text = response_text
                WHERE (guarded_response_text IS NULL OR TRIM(guarded_response_text) = '')
                  AND response_text IS NOT NULL;
                """
            ]
        ),
        MigrationStep(
            version: 6,
            statements: [
                "ALTER TABLE quick_assist_threads ADD COLUMN parent_thread_id TEXT",
                "ALTER TABLE quick_assist_threads ADD COLUMN branched_from_turn_id TEXT",
                """
                CREATE TABLE IF NOT EXISTS coach_findings (
                    id TEXT PRIMARY KEY,
                    session_id TEXT,
                    thread_id TEXT,
                    issue_type TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    status TEXT NOT NULL,
                    title TEXT NOT NULL,
                    message TEXT NOT NULL,
                    suggested_question TEXT NOT NULL,
                    suggested_context TEXT NOT NULL,
                    evidence_json TEXT,
                    dedupe_key TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    dismissed_at INTEGER
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_threads_parent ON quick_assist_threads(parent_thread_id)",
                "CREATE INDEX IF NOT EXISTS idx_coach_findings_session_status ON coach_findings(session_id, status, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_coach_findings_thread_status ON coach_findings(thread_id, status, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_coach_findings_dedupe_status ON coach_findings(dedupe_key, status)"
            ]
        )
    ]
}
