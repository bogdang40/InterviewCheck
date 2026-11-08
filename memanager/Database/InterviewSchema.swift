import Foundation

extension SessionDatabaseSchema {
    /// Cheating detector: interviews, every timed word, the questions asked,
    /// the AI answers generated for them, and the scores. Times inside an
    /// interview are milliseconds since it started.
    static let interviewStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS interviews (
            id TEXT PRIMARY KEY,
            workspace_id TEXT,
            role_title TEXT NOT NULL DEFAULT '',
            candidate_name TEXT NOT NULL DEFAULT '',
            consent_confirmed_at INTEGER,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            overall_percent INTEGER,
            flagged_count INTEGER NOT NULL DEFAULT 0,
            question_count INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS interview_words (
            interview_id TEXT NOT NULL,
            side TEXT NOT NULL,
            speaker_index INTEGER,
            text TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            confidence REAL,
            is_filler INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_interview_words_interview ON interview_words(interview_id, start_ms)",
        """
        CREATE TABLE IF NOT EXISTS interview_questions (
            id TEXT PRIMARY KEY,
            interview_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            text TEXT NOT NULL,
            source TEXT NOT NULL,
            marked_at_ms INTEGER NOT NULL,
            question_end_ms INTEGER,
            answer_start_ms INTEGER,
            answer_end_ms INTEGER,
            closed_at_ms INTEGER,
            answer_text TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_interview_questions_interview ON interview_questions(interview_id, ordinal)",
        """
        CREATE TABLE IF NOT EXISTS reference_answers (
            id TEXT PRIMARY KEY,
            question_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt_name TEXT NOT NULL,
            text TEXT NOT NULL,
            first_sentence_ms INTEGER,
            total_ms INTEGER,
            error TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_reference_answers_question ON reference_answers(question_id)",
        """
        CREATE TABLE IF NOT EXISTS answer_scores (
            question_id TEXT PRIMARY KEY,
            percent INTEGER NOT NULL,
            confidence TEXT NOT NULL,
            reasons TEXT NOT NULL,
            counterpoints TEXT NOT NULL,
            follow_ups TEXT NOT NULL,
            metrics TEXT NOT NULL,
            is_final INTEGER NOT NULL DEFAULT 0,
            computed_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS role_profiles (
            workspace_id TEXT PRIMARY KEY,
            profile TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
    ]

    static var interviewTables: String {
        interviewStatements.map { $0 + ";" }.joined(separator: "\n")
    }
}

extension SessionDatabaseMigrationSteps {
    static let interviews: [MigrationStep] = [
        MigrationStep(version: 17, statements: SessionDatabaseSchema.interviewStatements),
    ]
}
