import Foundation

/// Merges a role being edited with a newer stored copy: fields the editor
/// did not touch take the stored value (a background draft's questions and
/// prompts, an imported description); fields it did touch keep the edit.
enum RoleEditMerge {
    static func merge(local: RoleProfile, base: RoleProfile, latest: RoleProfile) -> RoleProfile {
        var merged = local
        if local.name == base.name { merged.name = latest.name }
        if local.company == base.company { merged.company = latest.company }
        if local.jobDescription == base.jobDescription { merged.jobDescription = latest.jobDescription }
        if local.plannedQuestions == base.plannedQuestions { merged.plannedQuestions = latest.plannedQuestions }
        if local.cheaterPrompts == base.cheaterPrompts { merged.cheaterPrompts = latest.cheaterPrompts }
        if local.externalJobKey == base.externalJobKey { merged.externalJobKey = latest.externalJobKey }
        return merged
    }

    /// Equal apart from the save time.
    static func sameContent(_ a: RoleProfile, _ b: RoleProfile) -> Bool {
        var left = a
        left.updatedAt = b.updatedAt
        return left == b
    }
}
