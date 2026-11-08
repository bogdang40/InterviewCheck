import SwiftUI

/// The identity chips at the head of the thread: answer family with its
/// framework, provider (a menu for OpenAI so raw and guarded answers are
/// one click apart), and the model tier.
struct QuickAssistHeaderBadges: View {
    let model: QuickAssistThreadHeaderModel
    let displayMode: Binding<OpenAIQuickAssistDisplayMode>
    let isVoiceGuardEnabled: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if let family = model.familyBadgeText {
                ToneBadge(text: family, tone: model.familyTone, systemImage: model.answerFamilyBadge?.isProbe == true ? "questionmark.circle" : "person.wave.2")
                    .help(model.answerFamilyBadge?.isProbe == true ? "The router treated this as a probe" : "Answer family and framework for this turn")
            }
            providerBadge
            ToneBadge(text: model.activeTier.badgeLabel, tone: model.activeTier.badgeTone, style: .outline, monospaced: true)
                .help(model.activeTier.helpText)
        }
    }

    @ViewBuilder
    private var providerBadge: some View {
        if model.shouldShowOpenAISourceMenu {
            Menu {
                Picker("Answer source", selection: displayMode) {
                    Text("Raw").tag(OpenAIQuickAssistDisplayMode.response)
                    Text("Guarded").tag(OpenAIQuickAssistDisplayMode.guarded)
                }
                .pickerStyle(.inline)
                .disabled(!isVoiceGuardEnabled)
                if !isVoiceGuardEnabled {
                    Text("Turn on the voice guard in Settings to compare")
                }
            } label: {
                ToneBadge(
                    text: "OpenAI \(model.selectedResponseSourceLabel ?? "Raw")",
                    tone: .info,
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(
                model.selectedOpenAIRawGuardedIdentical
                    ? "Voice guard made no changes to this answer"
                    : "Switch between the raw and the voice guarded answer"
            )
        } else if let provider = model.providerDisplayName {
            ToneBadge(text: provider, tone: .neutral, style: .outline)
                .help("Provider for this turn")
        }
    }
}
