import Foundation

struct QuickAssistExperimentCandidatePlan: Equatable {
    let label: String
    let role: QuickAssistCandidateRole
    let providerType: AIProviderType
    let modelTier: QuickAssistModelTier
}

struct QuickAssistExperimentContext {
    let baseCall: QuickAssistCallRecord
    let selectedIntent: QuickAssistIntent?
    let routeConfidence: Double?
    let availableProviders: [AIProviderType]
    let currentProvider: AIProviderType
}

protocol QuickAssistExperimentRunning {
    func candidatePlans(for context: QuickAssistExperimentContext) -> [QuickAssistExperimentCandidatePlan]
}

struct QuickAssistExperimentRunner: QuickAssistExperimentRunning {
    func candidatePlans(for context: QuickAssistExperimentContext) -> [QuickAssistExperimentCandidatePlan] {
        var plans: [QuickAssistExperimentCandidatePlan] = [
            QuickAssistExperimentCandidatePlan(
                label: "Current Route",
                role: .currentRoute,
                providerType: context.currentProvider,
                modelTier: context.baseCall.modelTier
            ),
            QuickAssistExperimentCandidatePlan(
                label: "Deep Tier",
                role: .sameProviderDeep,
                providerType: context.currentProvider,
                modelTier: .deep
            )
        ]

        if let alternateProvider = context.availableProviders.first(where: { $0 != context.currentProvider }) {
            plans.append(
                QuickAssistExperimentCandidatePlan(
                    label: "\(alternateProvider.displayName)",
                    role: .alternateProvider,
                    providerType: alternateProvider,
                    modelTier: context.baseCall.modelTier
                )
            )
        }

        return plans
    }
}

protocol QuickAssistOutcomeScoring {
    func score(
        call: QuickAssistCallRecord,
        preferredProvider: String?
    ) -> QuickAssistOutcomeScore
}

struct QuickAssistOutcomeScorer: QuickAssistOutcomeScoring {
    func score(
        call: QuickAssistCallRecord,
        preferredProvider: String?
    ) -> QuickAssistOutcomeScore {
        let verificationComponent: Double
        switch call.verificationStatus {
        case .verified:
            verificationComponent = 0.50
        case .needsReview:
            verificationComponent = 0.26
        case .pending:
            verificationComponent = 0.18
        case .failed:
            verificationComponent = 0.0
        }

        let unsupportedClaims = max(0, call.unsupportedClaimCount ?? 0)
        let unsupportedClaimPenalty = min(0.20, Double(unsupportedClaims) * 0.05)

        let feedbackComponent: Double
        switch call.userFeedbackStatus {
        case .accepted:
            feedbackComponent = 0.15
        case .rejected:
            feedbackComponent = 0.0
        case .none:
            feedbackComponent = 0.07
        }

        let latencyMs = max(1, call.durationMs ?? 1_500)
        let latencyComponent = max(0.0, 0.15 * (1.0 - min(Double(latencyMs), 8_000) / 8_000.0))
        let preferredProviderBoost = preferredProvider == call.provider ? 0.01 : 0.0
        let total = max(0, verificationComponent - unsupportedClaimPenalty + feedbackComponent + latencyComponent + preferredProviderBoost)
        let rationale = "verification=\(Int((verificationComponent * 100).rounded())) unsupported=\(unsupportedClaims) latency=\(latencyMs)ms feedback=\(call.userFeedbackStatus.rawValue)"

        return QuickAssistOutcomeScore(
            verificationComponent: verificationComponent,
            unsupportedClaimPenalty: unsupportedClaimPenalty,
            feedbackComponent: feedbackComponent,
            latencyComponent: latencyComponent,
            total: total,
            rationale: rationale
        )
    }
}

final class QuickAssistPolicyCalibrator {
    private let defaults = AppDefaults.standard
    private let key = "memanager.quickAssistPolicyCalibration"

    func preferredProvider(for intent: QuickAssistIntent?) -> String? {
        guard let intent else { return nil }
        return calibrationMap()[intent.rawValue]
    }

    func recordAcceptedWinner(candidate: QuickAssistCandidate, intent: QuickAssistIntent?) {
        guard let intent else { return }
        var map = calibrationMap()
        map[intent.rawValue] = candidate.provider
        defaults.set(map, forKey: key)
    }

    private func calibrationMap() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
