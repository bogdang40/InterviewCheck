extension SessionDatabaseSchema {
    static let indexes = """
        -- Create indexes
        CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
        CREATE INDEX IF NOT EXISTS idx_api_calls_session_id ON api_calls(session_id);
        CREATE INDEX IF NOT EXISTS idx_api_calls_provider ON api_calls(provider);
        CREATE INDEX IF NOT EXISTS idx_api_calls_started_at ON api_calls(started_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_threads_updated_at ON quick_assist_threads(updated_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_session_id ON quick_assist_calls(session_id);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_id ON quick_assist_calls(thread_id);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_id_started_at ON quick_assist_calls(thread_id, started_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_calls_started_at ON quick_assist_calls(started_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_policy_events_thread_id_created_at ON quick_assist_policy_events(thread_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_policy_events_session_id_created_at ON quick_assist_policy_events(session_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_pins_thread_id ON quick_assist_thread_pins(thread_id);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_thread_pins_memory_node_id ON quick_assist_thread_pins(memory_node_id);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_experiments_session_updated_at ON quick_assist_experiments(session_id, updated_at);
        CREATE INDEX IF NOT EXISTS idx_transcript_session_id ON transcript_entries(session_id);
        CREATE INDEX IF NOT EXISTS idx_transcript_entries_session_ts ON transcript_entries(session_id, timestamp);
        CREATE INDEX IF NOT EXISTS idx_screenshots_session_id ON screenshots(session_id);
        CREATE INDEX IF NOT EXISTS idx_provider_stats_date ON provider_stats(date);
        CREATE INDEX IF NOT EXISTS idx_debug_events_timestamp ON debug_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_debug_events_category ON debug_events(event_category);
        CREATE INDEX IF NOT EXISTS idx_debug_events_session ON debug_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_memory_nodes_session_id ON memory_nodes(session_id);
        CREATE INDEX IF NOT EXISTS idx_memory_nodes_source_type ON memory_nodes(source_type);
        CREATE INDEX IF NOT EXISTS idx_memory_nodes_updated_at ON memory_nodes(updated_at);
        CREATE INDEX IF NOT EXISTS idx_memory_relationships_from ON memory_relationships(from_node_id);
        CREATE INDEX IF NOT EXISTS idx_memory_relationships_to ON memory_relationships(to_node_id);
        CREATE INDEX IF NOT EXISTS idx_memory_retrieval_events_created_at ON memory_retrieval_events(created_at);
        CREATE INDEX IF NOT EXISTS idx_memory_retrieval_events_query_source ON memory_retrieval_events(query_source);
        CREATE INDEX IF NOT EXISTS idx_quick_assist_threads_parent ON quick_assist_threads(parent_thread_id);
        CREATE INDEX IF NOT EXISTS idx_coach_findings_session_status ON coach_findings(session_id, status, updated_at);
        CREATE INDEX IF NOT EXISTS idx_coach_findings_thread_status ON coach_findings(thread_id, status, updated_at);
        CREATE INDEX IF NOT EXISTS idx_coach_findings_dedupe_status ON coach_findings(dedupe_key, status);
        CREATE INDEX IF NOT EXISTS idx_session_debriefs_session_id ON session_debriefs(session_id);
        CREATE INDEX IF NOT EXISTS idx_session_debrief_drills_session_debrief ON session_debrief_drills(session_id, debrief_id);
        CREATE INDEX IF NOT EXISTS idx_session_snapshots_session_id ON session_snapshots(session_id, captured_at);
        CREATE INDEX IF NOT EXISTS idx_practice_cards_session ON practice_cards(session_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_practice_schedules_due ON practice_schedules(next_review_at);
        CREATE INDEX IF NOT EXISTS idx_practice_reviews_card ON practice_reviews(card_id, reviewed_at);
        CREATE INDEX IF NOT EXISTS idx_job_workspaces_updated_at ON job_workspaces(is_archived, updated_at);
        CREATE INDEX IF NOT EXISTS idx_workspace_documents_workspace ON workspace_documents(workspace_id, category);
        CREATE INDEX IF NOT EXISTS idx_workspace_journal_workspace ON workspace_journal(workspace_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_kg_nodes_kind_updated ON kg_nodes(kind, updated_at);
        CREATE INDEX IF NOT EXISTS idx_kg_nodes_workspace ON kg_nodes(workspace_id);
        CREATE INDEX IF NOT EXISTS idx_kg_edges_from ON kg_edges(from_node_id);
        CREATE INDEX IF NOT EXISTS idx_kg_edges_to ON kg_edges(to_node_id);
        """
}
