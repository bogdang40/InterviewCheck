import Foundation

/// Single source of truth for the interview question families Quick Assist
/// can answer. Detection, prompt contracts, capability composition, and the
/// UI badge all derive from this catalog, so adding a family is one data
/// edit in the matching group file.
enum InterviewPlaybookCatalog {

    /// The follow up probe: a delta answer anchored to the previous turn,
    /// never a fresh skeleton. Lives here rather than a group file because
    /// the classifier treats it as a cross cutting pseudo family.
    static let followUpProbe = InterviewAnswerPlaybook(
        id: "follow_up_probe",
        displayName: "Follow up",
        frameworkName: "Delta Answer",
        frameworkSummary: "Answer only what the interviewer is probing, anchored explicitly to the previous answer.",
        strongCues: [
            "tell me more",
            "can you elaborate",
            "elaborate on that",
            "dig deeper",
            "drill down",
            "what was the outcome",
            "why did you choose",
            "what would you do differently",
            "how did that scale",
            "what was your role in that"
        ],
        cues: ["follow up", "going back to", "you mentioned", "on that point"],
        beats: [],
        spokenLengthTarget: "30 to 60 seconds",
        voiceStyle: .spoken,
        allowsCode: false,
        allowsMermaid: false,
        legacyIntent: .conversation,
        depth: .spokenFast
    )

    /// Every playbook, probe last so cue collisions favor concrete families.
    static let playbooks: [InterviewAnswerPlaybook] =
        InterviewNarrativePlaybooks.all
            + InterviewBehavioralPlaybooks.all
            + InterviewTechnicalPlaybooks.all
            + InterviewDesignPlaybooks.all
            + InterviewDataQuantPlaybooks.all
            + InterviewProductMetaPlaybooks.all
            + [followUpProbe]

    private static let playbooksByID: [String: InterviewAnswerPlaybook] =
        Dictionary(uniqueKeysWithValues: playbooks.map { ($0.id, $0) })

    static func playbook(id: String) -> InterviewAnswerPlaybook? {
        playbooksByID[id]
    }

    /// Families whose answers are spoken narrative. Used when the user has
    /// explicitly selected the behavioural thread mode: classification is
    /// then restricted to this set so a technical false positive can never
    /// hijack a story answer.
    static var spokenFamilyIDs: Set<String> {
        Set(playbooks.filter { $0.voiceStyle == .spoken }.map(\.id))
    }
}
