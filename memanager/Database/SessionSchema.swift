enum SessionDatabaseSchema {
    static let sessionTables = """
        -- Sessions table
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            state TEXT NOT NULL,
            transcript TEXT,
            transcript_word_count INTEGER DEFAULT 0,
            screenshot_count INTEGER DEFAULT 0,
            has_response INTEGER DEFAULT 0,
            provider TEXT,
            model TEXT,
            created_at INTEGER NOT NULL
        );
        
        -- API Calls table (with full payload storage)
        CREATE TABLE IF NOT EXISTS api_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            call_type TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            completed_at INTEGER,
            duration_ms INTEGER,
            input_tokens INTEGER,
            output_tokens INTEGER,
            total_tokens INTEGER,
            status TEXT NOT NULL,
            error_message TEXT,
            request_size_bytes INTEGER,
            response_size_bytes INTEGER,
            is_streaming INTEGER DEFAULT 0,
            endpoint TEXT,
            system_prompt TEXT,
            request_payload TEXT,
            response_payload TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        
        -- Quick Assist Calls table (with full context storage)
        CREATE TABLE IF NOT EXISTS quick_assist_threads (
            id TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            title TEXT,
            origin_session_id TEXT,
            parent_thread_id TEXT,
            branched_from_turn_id TEXT,
            selected_mode TEXT NOT NULL DEFAULT 'auto'
        );

        CREATE TABLE IF NOT EXISTS quick_assist_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            completed_at INTEGER,
            duration_ms INTEGER,
            is_follow_up INTEGER DEFAULT 0,
            transcript_length INTEGER,
            has_screenshot INTEGER DEFAULT 0,
            has_previous_response INTEGER DEFAULT 0,
            response_length INTEGER,
            status TEXT NOT NULL,
            error_message TEXT,
            transcript_text TEXT,
            question TEXT,
            extra_context TEXT,
            request_payload TEXT,
            response_text TEXT,
            raw_response_text TEXT,
            guarded_response_text TEXT,
            previous_response TEXT,
            context_mode TEXT,
            model_tier TEXT,
            question_source TEXT,
            route_confidence REAL,
            verification_status TEXT,
            verification_confidence REAL,
            unsupported_claim_count INTEGER,
            verification_missing_questions TEXT,
            verification_suggested_follow_up TEXT,
            policy_version TEXT,
            route_override TEXT,
            evidence_pack_manifest TEXT,
            user_feedback_status TEXT,
            user_feedback_note TEXT,
            user_feedback_at INTEGER,
            experiment_group_id TEXT,
            candidate_label TEXT,
            base_turn_id TEXT,
            candidate_role TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );

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
        );

        CREATE TABLE IF NOT EXISTS quick_assist_thread_pins (
            thread_id TEXT NOT NULL,
            memory_node_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (thread_id, memory_node_id)
        );

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
        );
        
        -- Transcript Entries table
        CREATE TABLE IF NOT EXISTS transcript_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            speaker TEXT NOT NULL,
            text TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            confidence REAL,
            source TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        
        -- Screenshots table
        CREATE TABLE IF NOT EXISTS screenshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            captured_at INTEGER NOT NULL,
            width INTEGER,
            height INTEGER,
            size_bytes INTEGER,
            source TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id)
        );
        
        -- Provider Stats (aggregated)
        CREATE TABLE IF NOT EXISTS provider_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            call_type TEXT NOT NULL,
            call_count INTEGER DEFAULT 0,
            success_count INTEGER DEFAULT 0,
            error_count INTEGER DEFAULT 0,
            total_duration_ms INTEGER DEFAULT 0,
            total_input_tokens INTEGER DEFAULT 0,
            total_output_tokens INTEGER DEFAULT 0,
            avg_duration_ms REAL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(date, provider, model, call_type)
        );
        
        -- Debug Events table (for crash investigation and detailed flow logging)
        CREATE TABLE IF NOT EXISTS debug_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            event_type TEXT NOT NULL,
            event_category TEXT NOT NULL,
            event_name TEXT NOT NULL,
            details TEXT,
            stack_trace TEXT,
            thread_info TEXT,
            memory_usage_mb REAL,
            timestamp INTEGER NOT NULL,
            created_at INTEGER NOT NULL
        );

        """
}
