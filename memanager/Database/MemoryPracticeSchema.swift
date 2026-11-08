extension SessionDatabaseSchema {
    static let memoryAndPracticeTables = """
        -- Hub memory nodes (cross-session retrieval)
        CREATE TABLE IF NOT EXISTS memory_nodes (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            source_type TEXT NOT NULL,
            source_ref TEXT,
            thread_id TEXT,
            turn_id TEXT,
            question_source TEXT,
            intent TEXT,
            context_mode TEXT,
            content TEXT NOT NULL,
            summary TEXT,
            tags TEXT,
            importance INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );

        CREATE TABLE IF NOT EXISTS memory_relationships (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            from_node_id TEXT NOT NULL,
            to_node_id TEXT NOT NULL,
            relation_type TEXT NOT NULL,
            strength INTEGER DEFAULT 1,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (from_node_id) REFERENCES memory_nodes(id),
            FOREIGN KEY (to_node_id) REFERENCES memory_nodes(id)
        );

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
        );

        -- Proactive failure coach findings
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
        );

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
        );

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
        );

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
        );

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
        );

        CREATE TABLE IF NOT EXISTS practice_schedules (
            card_id TEXT PRIMARY KEY,
            repetition_count INTEGER NOT NULL,
            easiness REAL NOT NULL,
            interval_days INTEGER NOT NULL,
            next_review_at INTEGER NOT NULL,
            lapses INTEGER NOT NULL,
            last_reviewed_at INTEGER,
            FOREIGN KEY (card_id) REFERENCES practice_cards(id)
        );

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
        );

        """
}
