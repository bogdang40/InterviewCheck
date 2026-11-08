import Foundation

/// The complete schema migration ladder, one MigrationStep per version.
///
/// Definitions live in chronological extension files. Existing migration SQL
/// remains unchanged; schema changes append a new step and update the version.
enum SessionDatabaseMigrationSteps {
    static let currentVersion = 21

    static let all = quickAssistEvolution + memoryAndExperiments + practiceAndWorkspaces + interviews
}
