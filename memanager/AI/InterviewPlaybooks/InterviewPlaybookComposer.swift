import Foundation

/// Turns a classified question family into the same capability composition
/// shape the legacy intent composer produces, so the orchestration layer can
/// consume either without caring which one decided.
final class InterviewPlaybookComposer {

    func compose(
        resolution: InterviewFamilyResolution,
        resolvedContext: QuickAssistContextResolver.ResolvedContext
    ) -> QuickAssistCapabilityComposition {
        let playbook = resolution.playbook
        let manifest = [
            "family=\(playbook.id)",
            "framework=\(playbook.frameworkName)",
            "confidence=\(String(format: "%.2f", resolution.confidence))",
            "signals=\(resolution.signals.joined(separator: ", "))"
        ].joined(separator: ", ")

        return QuickAssistCapabilityComposition(
            contextModeOverride: contextModeOverride(for: playbook, resolvedContext: resolvedContext),
            complexityOverride: playbook.depth.complexity,
            modelTierOverride: playbook.depth.modelTier,
            outputContractOverride: playbook.outputContract,
            promptAddendum: nil,
            intentManifest: manifest,
            answerPlaybookContract: answerPlaybookContract(for: resolution)
        )
    }

    /// Spoken families never want solve section context bleeding into a
    /// story answer; technical families keep whatever the resolver found.
    private func contextModeOverride(
        for playbook: InterviewAnswerPlaybook,
        resolvedContext: QuickAssistContextResolver.ResolvedContext
    ) -> QuickAssistContextMode? {
        switch playbook.voiceStyle {
        case .spoken:
            return .conversation
        case .technical:
            return playbook.legacyIntent == .systemDesign ? .systemDesignContext : nil
        }
    }

    private func answerPlaybookContract(for resolution: InterviewFamilyResolution) -> String {
        var parts = [resolution.playbook.promptContract]
        if resolution.isProbe, let inheritedID = resolution.secondaryFamilyID,
           let inherited = InterviewPlaybookCatalog.playbook(id: inheritedID) {
            parts.append("The previous answer followed the \(inherited.frameworkName) playbook for a \(inherited.displayName) question. Stay consistent with it.")
        } else if let secondaryID = resolution.secondaryFamilyID,
                  let secondary = InterviewPlaybookCatalog.playbook(id: secondaryID) {
            parts.append("The question also carries a \(secondary.displayName) part. After the main beats, close it in one or two sentences so it is not forgotten.")
        }
        return parts.joined(separator: "\n")
    }
}
