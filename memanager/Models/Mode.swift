import Foundation

/// A Mode is a named prompt with optional document attachments and an optional
/// read only project folder scope. The active Mode is injected into every Quick Assist call.
///
/// Modes replace the legacy `QuickAssistPrompt` concept. Existing prompts are migrated into
/// Modes with empty attachments on first run via `ModeMigrator`.
struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var prompt: String
    var attachments: [ModeAttachment]
    var projectFolder: ProjectFolderConfig?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        attachments: [ModeAttachment] = [],
        projectFolder: ProjectFolderConfig? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.attachments = attachments
        self.projectFolder = projectFolder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Back compat shape for code paths that still expect the legacy `QuickAssistPrompt`.
    var asLegacyPrompt: QuickAssistPrompt {
        QuickAssistPrompt(id: id, title: title, prompt: prompt)
    }

    /// Convenience: builds a Mode from an existing `QuickAssistPrompt` with no attachments.
    init(legacy prompt: QuickAssistPrompt, importedAt: Date = Date()) {
        self.id = prompt.id
        self.title = prompt.title
        self.prompt = prompt.prompt
        self.attachments = []
        self.projectFolder = nil
        self.createdAt = importedAt
        self.updatedAt = importedAt
    }
}
