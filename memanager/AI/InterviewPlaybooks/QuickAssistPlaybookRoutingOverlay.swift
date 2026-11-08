import Foundation

/// The overlay's verdict for one Quick Assist turn: which resolution and
/// composition actually drive the request, which interaction mode the prompt
/// should speak in, and the family that was detected, if any.
struct QuickAssistPlaybookRoutingDecision {
    let intentResolution: QuickAssistIntentResolution
    let composition: QuickAssistCapabilityComposition
    let promptInteractionMode: QuickAssistInteractionMode
    let familyResolution: InterviewFamilyResolution?
}

/// Layers interview family awareness over the legacy intent routing without
/// replacing it. The base route is computed first; the overlay classifies
/// the question against the playbook catalog and takes over only where the
/// family evidence is strong enough, so every legacy behavior remains the
/// fallback. This is the fix for the two sharpest routing gaps: behavioural
/// answers were a single STAR shaped hammer, and the spoken interaction mode
/// was never inferred for auto threads.
final class QuickAssistPlaybookRoutingOverlay {

    /// Minimum classifier confidence before a family may hijack an auto
    /// routed technical turn. Score two or better: a strong cue, or a cue
    /// corroborated by supporting context.
    private let autoDriveConfidenceThreshold = 0.72

    private let classifier = InterviewQuestionClassifier()
    private let composer = InterviewPlaybookComposer()

    func apply(
        baseIntentResolution: QuickAssistIntentResolution,
        baseComposition: QuickAssistCapabilityComposition,
        interactionMode: QuickAssistInteractionMode,
        questionSource: QuickAssistQuestionSource,
        question: String,
        transcript: String,
        extraContext: String,
        threadModePreferredIntent: QuickAssistIntent?,
        previousFamilyID: String?,
        resolvedContext: QuickAssistContextResolver.ResolvedContext
    ) -> QuickAssistPlaybookRoutingDecision {
        let resolution = familyResolution(
            interactionMode: interactionMode,
            questionSource: questionSource,
            question: question,
            transcript: transcript,
            extraContext: extraContext,
            previousFamilyID: previousFamilyID
        )

        guard let resolution else {
            return passthrough(baseIntentResolution, baseComposition, interactionMode, nil)
        }

        let familyDrives: Bool = {
            if interactionMode == .behavioural { return true }
            if let preferred = threadModePreferredIntent {
                return resolution.playbook.legacyIntent == preferred
            }
            return resolution.confidence >= autoDriveConfidenceThreshold
        }()

        guard familyDrives else {
            let annotated = QuickAssistIntentResolution(
                intent: baseIntentResolution.intent,
                confidence: baseIntentResolution.confidence,
                signals: baseIntentResolution.signals + resolution.signals
            )
            return passthrough(annotated, baseComposition, interactionMode, resolution)
        }

        let composition = composer.compose(resolution: resolution, resolvedContext: resolvedContext)
        let drivenResolution = QuickAssistIntentResolution(
            intent: resolution.playbook.legacyIntent,
            confidence: resolution.confidence,
            signals: baseIntentResolution.signals + resolution.signals
        )
        let promptInteractionMode: QuickAssistInteractionMode =
            resolution.playbook.voiceStyle == .spoken ? .behavioural : .technical

        return QuickAssistPlaybookRoutingDecision(
            intentResolution: drivenResolution,
            composition: composition,
            promptInteractionMode: promptInteractionMode,
            familyResolution: resolution
        )
    }

    // MARK: - Classification

    private func familyResolution(
        interactionMode: QuickAssistInteractionMode,
        questionSource: QuickAssistQuestionSource,
        question: String,
        transcript: String,
        extraContext: String,
        previousFamilyID: String?
    ) -> InterviewFamilyResolution? {
        if interactionMode == .behavioural && questionSource == .auto {
            // Auto side questions continue the thread; a fresh STAR skeleton
            // would be wrong, so they inherit the delta answer playbook.
            return InterviewFamilyResolution(
                playbook: InterviewPlaybookCatalog.followUpProbe,
                confidence: 0.9,
                signals: ["family=\(InterviewPlaybookCatalog.followUpProbe.id)", "probe_cue=auto_side_question"],
                secondaryFamilyID: previousFamilyID,
                isProbe: true
            )
        }

        let restriction: Set<String>? = interactionMode == .behavioural
            ? InterviewPlaybookCatalog.spokenFamilyIDs
            : nil
        let fallback: String? = interactionMode == .behavioural
            ? "behavioral_story"
            : nil

        return classifier.classify(
            InterviewQuestionClassifier.Input(
                question: question,
                transcript: transcript,
                extraContext: extraContext,
                questionSource: questionSource,
                previousFamilyID: previousFamilyID,
                allowedFamilyIDs: restriction,
                defaultFamilyID: fallback
            )
        )
    }

    private func passthrough(
        _ intentResolution: QuickAssistIntentResolution,
        _ composition: QuickAssistCapabilityComposition,
        _ interactionMode: QuickAssistInteractionMode,
        _ familyResolution: InterviewFamilyResolution?
    ) -> QuickAssistPlaybookRoutingDecision {
        QuickAssistPlaybookRoutingDecision(
            intentResolution: intentResolution,
            composition: composition,
            promptInteractionMode: interactionMode,
            familyResolution: familyResolution
        )
    }
}
