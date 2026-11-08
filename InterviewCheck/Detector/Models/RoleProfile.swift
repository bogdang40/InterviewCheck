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

/// A role being hired for: the job description, planned questions, and the
/// cheater prompts that imitate a candidate's tool for this job. Stored as
/// one JSON row in `role_profiles` (the `workspace_id` column is the role id).
struct RoleProfile: Codable, Equatable, Identifiable {
    var workspaceID: String
    var name: String = ""
    var company: String = ""
    var jobDescription: String = ""
    var cheaterPrompts: [CheaterPrompt] = CheaterPromptLibrary.defaults
    var plannedQuestions: [PlannedQuestion] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// "greenhouse:4012" when the role came from a job in a connected system.
    var externalJobKey: String?

    var id: String { workspaceID }
    var enabledPrompts: [CheaterPrompt] { cheaterPrompts.filter(\.isEnabled) }

    /// "Senior Backend Engineer at Acme", or whatever parts exist.
    var displayTitle: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, company.isEmpty) {
        case (false, false): return "\(name) at \(company)"
        case (false, true): return name
        case (true, false): return company
        case (true, true): return "Untitled role"
        }
    }

    init(workspaceID: String = UUID().uuidString, name: String = "", company: String = "",
         jobDescription: String = "") {
        self.workspaceID = workspaceID
        self.name = name
        self.company = company
        self.jobDescription = jobDescription
    }

    /// Older saved profiles lack the newer fields; they get defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? ""
        jobDescription = try container.decodeIfPresent(String.self, forKey: .jobDescription) ?? ""
        cheaterPrompts = try container.decodeIfPresent([CheaterPrompt].self, forKey: .cheaterPrompts)
            ?? CheaterPromptLibrary.defaults
        plannedQuestions = try container.decodeIfPresent([PlannedQuestion].self, forKey: .plannedQuestions) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        externalJobKey = try container.decodeIfPresent(String.self, forKey: .externalJobKey)
    }
}

/// One provider and model that produces reference answers.
struct LineupEntry: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var provider: AIProviderType
    var model: String
    var isEnabled: Bool = true
}
