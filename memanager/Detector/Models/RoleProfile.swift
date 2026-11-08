import Foundation

/// Instructions that imitate what a candidate's cheating tool runs. Each
/// enabled prompt produces one AI answer per provider in the lineup.
struct CheaterPrompt: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var instructions: String
    var isEnabled: Bool = true
    /// The built-in "Copilot" prompt is the original app's own answer
    /// prompt; its instructions are generated, not edited.
    var isBuiltIn: Bool = false
}

/// A question the interviewer plans to ask, drafted from the job description.
struct PlannedQuestion: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var text: String
    /// Playbook family (behavioral, system design, ...), when classified.
    var family: String?
    /// What a strong answer covers, for the interviewer.
    var strongAnswer: String
}

/// Everything the detector keeps about a role, beside its workspace folder.
struct RoleProfile: Codable, Equatable {
    var workspaceID: String
    var jobDescription: String = ""
    var cheaterPrompts: [CheaterPrompt] = CheaterPromptLibrary.defaults
    var plannedQuestions: [PlannedQuestion] = []
    var updatedAt = Date()

    var enabledPrompts: [CheaterPrompt] { cheaterPrompts.filter(\.isEnabled) }
}

/// One provider and model that produces reference answers.
struct LineupEntry: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var provider: AIProviderType
    var model: String
    var isEnabled: Bool = true
}
