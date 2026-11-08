import Foundation

extension SessionDatabaseMigrationSteps {
    static let memoryAndExperiments: [MigrationStep] = [
        MigrationStep(
            version: 7,
            statements: [
                "ALTER TABLE memory_nodes ADD COLUMN thread_id TEXT",
                "ALTER TABLE memory_nodes ADD COLUMN turn_id TEXT",
                "ALTER TABLE memory_nodes ADD COLUMN question_source TEXT",
                "ALTER TABLE memory_nodes ADD COLUMN intent TEXT",
                "ALTER TABLE memory_nodes ADD COLUMN context_mode TEXT",
                """
                CREATE TABLE IF NOT EXISTS memory_retrieval_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    query_source TEXT NOT NULL,
                    query_text TEXT NOT NULL,
                    query_tokens TEXT,
                    anchor_query TEXT,
                    expansion_query TEXT,
                    hit_count INTEGER DEFAULT 0,
                    top_node_ids TEXT,
                    top_score REAL DEFAULT 0,
                    confidence REAL DEFAULT 0,
                    latency_ms INTEGER DEFAULT 0,
                    session_id TEXT,
                    thread_id TEXT,
                    turn_id TEXT,
                    created_at INTEGER NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_memory_nodes_thread_id_updated_at ON memory_nodes(thread_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_memory_retrieval_events_created_at ON memory_retrieval_events(created_at)",
                "CREATE INDEX IF NOT EXISTS idx_memory_retrieval_events_query_source ON memory_retrieval_events(query_source)"
            ],
            backfills: [
                """
                UPDATE memory_nodes
                SET thread_id = CASE
                        WHEN source_ref IS NOT NULL AND instr(source_ref, ':') > 0
                        THEN substr(source_ref, 1, instr(source_ref, ':') - 1)
                        ELSE thread_id
                    END,
                    turn_id = CASE
                        WHEN source_ref IS NOT NULL AND instr(source_ref, ':') > 0
                        THEN substr(source_ref, instr(source_ref, ':') + 1)
                        ELSE turn_id
                    END
                WHERE source_ref IS NOT NULL
                  AND instr(source_ref, ':') > 0
                  AND (thread_id IS NULL OR TRIM(thread_id) = '' OR turn_id IS NULL OR TRIM(turn_id) = '');
                """,
                """
                UPDATE memory_nodes
                SET question_source = CASE
                        WHEN lower(IFNULL(tags, '')) LIKE '%auto%' THEN 'auto'
                        WHEN lower(IFNULL(tags, '')) LIKE '%manual%' THEN 'manual'
                        ELSE 'none'
                    END
                WHERE question_source IS NULL OR TRIM(question_source) = '';
                """,
                """
                UPDATE memory_nodes
                SET intent = CASE
                        WHEN lower(IFNULL(tags, '')) LIKE '%debug%' THEN 'debug'
                        WHEN lower(IFNULL(tags, '')) LIKE '%walkthrough%' THEN 'walkthrough'
                        WHEN lower(IFNULL(tags, '')) LIKE '%clarify%' THEN 'clarify'
                        WHEN lower(IFNULL(tags, '')) LIKE '%systemdesign%' THEN 'systemDesign'
                        ELSE 'conversation'
                    END
                WHERE intent IS NULL OR TRIM(intent) = '';
                """,
                """
                UPDATE memory_nodes
                SET context_mode = CASE
                        WHEN lower(IFNULL(tags, '')) LIKE '%systemdesigncontext%' THEN 'systemDesignContext'
                        WHEN lower(IFNULL(tags, '')) LIKE '%implementationcontext%' THEN 'implementationContext'
                        WHEN lower(IFNULL(tags, '')) LIKE '%allsectionscontext%' THEN 'allSectionsContext'
                        ELSE 'conversation'
                    END
                WHERE context_mode IS NULL OR TRIM(context_mode) = '';
                """
            ]
        ),
        MigrationStep(
            version: 8,
            statements: [
                "ALTER TABLE quick_assist_calls ADD COLUMN route_confidence REAL",
                "ALTER TABLE quick_assist_calls ADD COLUMN verification_status TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN verification_confidence REAL",
                "ALTER TABLE quick_assist_calls ADD COLUMN unsupported_claim_count INTEGER",
                "ALTER TABLE quick_assist_calls ADD COLUMN verification_missing_questions TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN verification_suggested_follow_up TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN policy_version TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN route_override TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN evidence_pack_manifest TEXT",
                """
                CREATE TABLE IF NOT EXISTS quick_assist_policy_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    thread_id TEXT NOT NULL,
                    turn_id TEXT NOT NULL,
                    policy_version TEXT NOT NULL,
                    selected_intent TEXT NOT NULL,
                    route_confidence REAL DEFAULT 0,
                    route_override TEXT,
                    decision_vector TEXT,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_policy_events_thread_id_created_at ON quick_assist_policy_events(thread_id, created_at)",
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_policy_events_session_id_created_at ON quick_assist_policy_events(session_id, created_at)"
            ],
            backfills: [
                """
                UPDATE quick_assist_calls
                SET verification_status = CASE
                    WHEN status = 'success' THEN 'pending'
                    WHEN status = 'error' THEN 'failed'
                    ELSE 'pending'
                END
                WHERE verification_status IS NULL OR TRIM(verification_status) = '';
                """,
                """
                UPDATE quick_assist_calls
                SET route_confidence = CASE
                    WHEN route_confidence IS NULL AND status = 'success' THEN 0.5
                    ELSE route_confidence
                END;
                """
            ]
        ),
        MigrationStep(
            version: 9,
            statements: [
                "ALTER TABLE quick_assist_calls ADD COLUMN user_feedback_status TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN user_feedback_note TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN user_feedback_at INTEGER",
                """
                CREATE TABLE IF NOT EXISTS quick_assist_thread_pins (
                    thread_id TEXT NOT NULL,
                    memory_node_id TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (thread_id, memory_node_id)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_pins_thread_id ON quick_assist_thread_pins(thread_id)",
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_pins_memory_node_id ON quick_assist_thread_pins(memory_node_id)"
            ],
            backfills: [
                """
                UPDATE quick_assist_calls
                SET user_feedback_status = 'none'
                WHERE user_feedback_status IS NULL OR TRIM(user_feedback_status) = '';
                """
            ]
        ),
        MigrationStep(
            version: 10,
            statements: [
                "ALTER TABLE quick_assist_calls ADD COLUMN experiment_group_id TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN candidate_label TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN base_turn_id TEXT",
                "ALTER TABLE quick_assist_calls ADD COLUMN candidate_role TEXT",
                """
                CREATE TABLE IF NOT EXISTS quick_assist_experiments (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    source_thread_id TEXT NOT NULL,
                    source_turn_id TEXT NOT NULL,
                    selected_intent TEXT,
                    route_confidence REAL,
                    status TEXT NOT NULL,
                    winner_candidate_id TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_debriefs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL UNIQUE,
                    what_happened TEXT NOT NULL,
                    strong_moments TEXT NOT NULL,
                    missed_opportunities TEXT NOT NULL,
                    recommended_drills TEXT NOT NULL,
                    next_session_focus TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_debrief_drills (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    debrief_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    transcript_span TEXT NOT NULL,
                    related_thread_id TEXT,
                    related_turn_id TEXT,
                    created_at INTEGER NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS session_snapshots (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    captured_at INTEGER NOT NULL,
                    width INTEGER NOT NULL,
                    height INTEGER NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    encrypted_payload BLOB NOT NULL,
                    created_at INTEGER NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_experiments_session_updated_at ON quick_assist_experiments(session_id, updated_at)",
                "CREATE INDEX IF NOT EXISTS idx_quick_assist_calls_experiment_group ON quick_assist_calls(experiment_group_id, started_at)",
                "CREATE INDEX IF NOT EXISTS idx_session_debriefs_session_id ON session_debriefs(session_id)",
                "CREATE INDEX IF NOT EXISTS idx_session_debrief_drills_session_debrief ON session_debrief_drills(session_id, debrief_id)",
                "CREATE INDEX IF NOT EXISTS idx_session_snapshots_session_id ON session_snapshots(session_id, captured_at)"
            ]
        ),
        MigrationStep(
            version: 11,
            statements: [
                "ALTER TABLE quick_assist_threads ADD COLUMN selected_mode TEXT NOT NULL DEFAULT 'auto'"
            ],
            backfills: [
                """
                UPDATE quick_assist_threads
                SET selected_mode = 'auto'
                WHERE selected_mode IS NULL OR TRIM(selected_mode) = '';
                """
            ]
        )
    ]
}
