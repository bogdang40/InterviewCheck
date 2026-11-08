import SwiftUI

/// Family and turn position stay near the answer. Context and provider
/// controls are available in the labelled inspector.
struct QuickAssistThreadHeader: View {
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    let plan: QuickAssistStudioLayoutPlan
    let displayMode: Binding<OpenAIQuickAssistDisplayMode>
    let isVoiceGuardEnabled: Bool
    private var model: QuickAssistThreadHeaderModel { QuickAssistThreadHeaderModel(state: state) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.md) { mode; Spacer(minLength: 0); navigator }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) { mode; navigator }
        }
    }

    private var mode: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            QuickAssistThreadModeMenu(
                selectedMode: model.selectedMode, resolvedCaption: model.resolvedModeCaption,
                showsCaption: plan.showsResolvedModeCaption, isLoading: model.isLoading,
                onSetMode: actions.onSetThreadMode
            )
            if let family = model.familyBadgeText {
                Text(family).font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .lineLimit(1).help("Answer family for the selected turn")
            }
        }
    }

    @ViewBuilder private var navigator: some View {
        if model.shouldShowTurnNavigator {
            HStack(spacing: DesignTokens.Spacing.xs) {
                QuickAssistTurnNavigator(
                    model: model.navigator, onSelectTurn: actions.onSelectTurn,
                    onPrevious: actions.onPreviousResponse, onNext: actions.onNextResponse
                )
                if let index = state.selectedIndex, index < state.responseCount - 1 {
                    Button("Latest") { actions.onSelectTurn(state.responseCount - 1) }
                        .buttonStyle(.overlay(.ghost, size: .small))
                        .disabled(state.isLoading)
                        .help("Return to the latest answer")
                }
            }
        }
    }
}
