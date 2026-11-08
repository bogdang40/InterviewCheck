import Foundation

/// How the candidate's answer should sound for a question family.
enum InterviewAnswerVoiceStyle: String, Equatable {
    /// Natural spoken narrative. No code or diagrams unless explicitly asked.
    case spoken
    /// Full technical depth with code and diagrams when they add value.
    case technical
}

/// Default depth profile a playbook applies when it drives the response.
struct InterviewAnswerDepth: Equatable {
    let complexity: QuickAssistComplexity
    let modelTier: QuickAssistModelTier
    let detailLevel: QuickAssistDetailLevel
    let responseShape: QuickAssistResponseShape

    /// Short spoken answers: fast tier, concise, conversational.
    static let spokenFast = InterviewAnswerDepth(
        complexity: .moderate,
        modelTier: .fast,
        detailLevel: .concise,
        responseShape: .conversational
    )

    /// Substantial spoken answers that still avoid technical formatting.
    static let spokenDeep = InterviewAnswerDepth(
        complexity: .deep,
        modelTier: .deep,
        detailLevel: .detailed,
        responseShape: .conversational
    )

    /// Structured technical answers without a code default.
    static let structuredDeep = InterviewAnswerDepth(
        complexity: .deep,
        modelTier: .deep,
        detailLevel: .detailed,
        responseShape: .structured
    )

    /// Implementation heavy answers where code is expected.
    static let implementationDeep = InterviewAnswerDepth(
        complexity: .deep,
        modelTier: .deep,
        detailLevel: .detailed,
        responseShape: .implementation
    )

    /// Architecture answers where diagrams carry the explanation.
    static let architectureDeep = InterviewAnswerDepth(
        complexity: .deep,
        modelTier: .deep,
        detailLevel: .detailed,
        responseShape: .architecture
    )
}

/// One interview question family's answering playbook: how to detect the
/// family, which framework strong candidates use for it, and the response
/// beats the model must deliver so the candidate can speak the answer.
///
/// Playbooks are pure data. Detection lives in `InterviewQuestionClassifier`,
/// prompt rendering in `InterviewAnswerPlaybook+Contract`, and capability
/// composition in `InterviewPlaybookComposer`. The catalog is the single
/// source of truth the prompt contract and the UI badge both derive from,
/// mirroring how `SystemDesignBlueprint` anchors the design surface.
struct InterviewAnswerPlaybook: Identifiable, Equatable {
    /// Stable id, recorded in routing signals as "family=<id>".
    let id: String
    /// Human readable family name shown in the UI badge.
    let displayName: String
    /// Framework name shown next to the family, for example "STAR-L".
    let frameworkName: String
    /// One sentence framework description injected into the prompt.
    let frameworkSummary: String
    /// Phrases that alone decide the family. Score 3 per hit.
    let strongCues: [String]
    /// Supporting phrases. Score 1 per hit.
    let cues: [String]
    /// Ordered beats as "Label: guidance" pairs. Empty for delta style
    /// playbooks such as the follow up probe.
    let beats: [String]
    /// Target spoken duration injected into the contract.
    let spokenLengthTarget: String
    let voiceStyle: InterviewAnswerVoiceStyle
    let allowsCode: Bool
    let allowsMermaid: Bool
    /// Legacy intent this family maps to for persistence and telemetry.
    let legacyIntent: QuickAssistIntent
    let depth: InterviewAnswerDepth

    /// Output contract override derived from the depth profile plus the
    /// playbook's beat labels as required elements.
    var outputContract: QuickAssistOutputContract {
        QuickAssistOutputContract(
            detailLevel: depth.detailLevel,
            enforceFirstPerson: true,
            responseShape: depth.responseShape,
            requiredElements: requiredElementKeys
        )
    }

    /// Machine readable beat keys, for example "beat_situation".
    var requiredElementKeys: [String] {
        beats.compactMap { beat in
            guard let label = beat.split(separator: ":").first else { return nil }
            let key = label
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            guard !key.isEmpty else { return nil }
            return "beat_\(key)"
        }
    }
}
