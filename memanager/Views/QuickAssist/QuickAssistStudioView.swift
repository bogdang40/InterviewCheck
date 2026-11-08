import SwiftUI

/// The answer keeps the available height; drafts and secondary controls
/// open from a contextual shelf without changing the selected turn.
struct QuickAssistStudioView: View {
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    @ObservedObject var settings = SettingsManager.shared
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.floatingDockLayout) private var floatingDock
    @FocusState private var isQuestionFocused: Bool
    @State private var questionFocusRequest = QuickAssistFocusRequest()
    @State private var historyFocusRequest = QuickAssistFocusRequest()
    @State private var focusHistorySearchOnOpen = false
    @State private var showsComposer = false
    @State private var inspector: QuickAssistInspector.Tab?
    @State private var drawer: ContextDrawer.Tab?

    var primaryInsight: QuickAssistPrimaryInsight {
        QuickAssistPrimaryInsightResolver.resolve(input: QuickAssistPrimaryInsightResolverInput(
            feedbackStatus: state.feedbackStatus, verificationRecord: state.verificationRecord,
            recoveryPlan: state.recoveryPlan, coachFindings: state.coachFindings,
            hubNudge: state.hubNudge, routeSummary: state.routeSummary,
            contextStatusMessage: state.contextStatusMessage, activeThreadID: state.activeThreadID
        ))
    }

    var effectiveDisplayModeBinding: Binding<OpenAIQuickAssistDisplayMode> {
        Binding(
            get: { settings.openAIVoiceGuardEnabled ? settings.openAIQuickAssistDisplayMode : .response },
            set: { settings.openAIQuickAssistDisplayMode = settings.openAIVoiceGuardEnabled ? $0 : .response }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let plan = QuickAssistStudioLayoutResolver.resolve(availableWidth: geometry.size.width)
            VStack(spacing: 0) {
                QuickAssistThreadHeader(
                    state: state, actions: actions, plan: plan,
                    displayMode: effectiveDisplayModeBinding,
                    isVoiceGuardEnabled: settings.openAIVoiceGuardEnabled
                )
                .padding(.horizontal, OverlayLayout.stageInset)
                .padding(.vertical, DesignTokens.Spacing.sm)
                QuickAssistStage(state: state, actions: actions, plan: plan, fontSize: settings.fontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if primaryInsight.tone == .critical || primaryInsight.tone == .warning {
                    QuickAssistInsightBanner(insight: primaryInsight, onAction: performPrimaryInsightAction)
                        .padding(.horizontal, OverlayLayout.stageInset)
                        .padding(.bottom, DesignTokens.Spacing.sm)
                }
                if showsComposer || !state.showsStage {
                    composer.frame(height: min(260, geometry.size.height * 0.38))
                }
                if let dock = floatingDock {
                    Color.clear.frame(height: dock.gap).allowsHitTesting(false)
                } else {
                    Hairline()
                }
                QuickAssistActionShelf(
                    state: state, actions: actions, onAsk: focusQuestion,
                    onSources: { inspector = .sources },
                    onTranscript: { drawer = .transcript },
                    onConversation: { focusHistorySearchOnOpen = false; drawer = .threads },
                    onOptions: { inspector = .review }
                )
                .frame(height: floatingDock?.height)
            }
        }
        .sheet(item: $inspector) { tab in
            QuickAssistInspector(
                state: state, actions: actions, initialTab: tab,
                displayMode: effectiveDisplayModeBinding,
                isVoiceGuardEnabled: settings.openAIVoiceGuardEnabled,
                onFocusQuestion: { inspector = nil; focusQuestion() },
                onClose: { inspector = nil }
            )
            .frame(minWidth: 360, idealWidth: 620, minHeight: 420, idealHeight: 640)
        }
        .sheet(item: $drawer, onDismiss: { focusHistorySearchOnOpen = false }) { tab in
            ContextDrawer(initialTab: tab, historySearchFocusRequested: $focusHistorySearchOnOpen, onClose: { drawer = nil })
                .frame(minWidth: 360, idealWidth: 620, minHeight: 420, idealHeight: 640)
        }
        .onAppear {
            if !state.question.wrappedValue.isEmpty { showsComposer = true }
            handleQuestionFocusRequest()
            handleHistoryFocusRequest()
        }
        .onChange(of: state.questionFocusNonce) { _, _ in handleQuestionFocusRequest() }
        .onChange(of: state.historySearchFocusNonce) { _, _ in handleHistoryFocusRequest() }
        .onChange(of: isEnabled) { _, active in
            if active {
                handleQuestionFocusRequest()
                handleHistoryFocusRequest()
            } else {
                isQuestionFocused = false
                inspector = nil
                drawer = nil
            }
        }
        .onDisappear { isQuestionFocused = false }
    }

    private var composer: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.xs) {
                HStack {
                    Text("Ask a question").font(OverlayType.heading)
                    Spacer()
                    if state.showsStage {
                        Button("Return to answer") { showsComposer = false; isQuestionFocused = false }
                            .buttonStyle(.overlay(.ghost, size: .small))
                    }
                }
                QuickAssistComposer(
                    question: state.question, extraContext: state.extraContext,
                    isExtraContextExpanded: state.isExtraContextExpanded,
                    contextHints: state.contextHints, contextStatusMessage: state.contextStatusMessage,
                    isLoading: state.isLoading, questionFocus: $isQuestionFocused,
                    onAsk: actions.onAskSideQuestion, onAutoSideQuestion: actions.onAutoSideQuestion
                )
            }
            .padding(.horizontal, OverlayLayout.stageInset)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private func focusQuestion() {
        guard isEnabled else { return }
        showsComposer = true
        isQuestionFocused = true
    }

    private func handleQuestionFocusRequest() {
        guard questionFocusRequest.consume(state.questionFocusNonce, isActive: isEnabled) else { return }
        inspector = nil
        drawer = nil
        focusQuestion()
    }

    private func handleHistoryFocusRequest() {
        guard historyFocusRequest.consume(state.historySearchFocusNonce, isActive: isEnabled) else { return }
        isQuestionFocused = false
        inspector = nil
        focusHistorySearchOnOpen = true
        drawer = .threads
    }

    private func performPrimaryInsightAction(_ action: QuickAssistPrimaryInsightAction) {
        switch action {
        case .recovery(let value): actions.onApplyRecoveryAction(value)
        case .applyCoachSuggestion(let id): actions.onApplyCoachSuggestion(id)
        case .openTimeline(let id): actions.onOpenTimeline(id)
        case .dismissCoachFinding(let id): actions.onDismissCoachFinding(id)
        case .dismissHubNudge: actions.onDismissHubNudge()
        case .focusQuestion: focusQuestion(); actions.onFocusQuestion()
        }
    }
}
