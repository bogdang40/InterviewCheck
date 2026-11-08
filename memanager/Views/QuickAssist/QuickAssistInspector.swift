import SwiftUI

/// Secondary work stays reachable without covering the answer permanently.
/// All controls operate on the same studio state as the reading column.
struct QuickAssistInspector: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sources = "Sources", context = "Context", activity = "Tools", review = "Review", thread = "Thread", coaching = "Coaching"
        var id: String { rawValue }
    }
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    let displayMode: Binding<OpenAIQuickAssistDisplayMode>
    let isVoiceGuardEnabled: Bool
    let onFocusQuestion: () -> Void
    let onClose: () -> Void
    @State private var tab: Tab
    @State private var expandedTools: Set<String> = []
    @State private var threadExpanded = true
    @State private var showsKeys = false

    init(state: QuickAssistStudioState, actions: QuickAssistStudioActions, initialTab: Tab,
         displayMode: Binding<OpenAIQuickAssistDisplayMode>, isVoiceGuardEnabled: Bool,
         onFocusQuestion: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.state = state; self.actions = actions; self.displayMode = displayMode
        self.isVoiceGuardEnabled = isVoiceGuardEnabled
        self.onFocusQuestion = onFocusQuestion; self.onClose = onClose
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Answer options").font(OverlayType.heading)
                Spacer()
                Button("Return to answer", action: onClose).buttonStyle(.overlay(.secondary))
            }
            .padding(DesignTokens.Spacing.lg)
            SegmentStrip(items: Tab.allCases.map { SegmentItem(id: $0, title: $0.rawValue) }, selection: $tab)
                .padding(.horizontal, DesignTokens.Spacing.md)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    switch tab {
                    case .sources:
                        QuickAssistSourcesView(presentation: state.savedSources) { tab = .context }
                    case .context: context
                    case .activity: activity
                    case .review: review
                    case .thread:
                        QuickAssistThreadToolsCard(state: state, actions: actions, isExpanded: $threadExpanded)
                    case .coaching: coaching
                    }
                }
                .padding(DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(OverlayPalette.readingSurface)
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Context for the next question").font(OverlayType.title)
            Text("These choices affect future requests. They do not change the sources recorded for an earlier answer.")
                .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
            HStack { Text("Workspace"); Spacer(); QuickAssistWorkspacePill() }
            Hairline()
            HStack { Text("Knowledge"); Spacer(); QuickAssistKnowledgePill() }
            QuickAssistComposerContextChips(hints: state.contextHints, contextStatusMessage: state.contextStatusMessage)
            QuickAssistExtraContextDisclosure(
                extraContext: state.extraContext, isExpanded: state.isExtraContextExpanded, isLoading: state.isLoading
            )
            MemoryDrawerSection()
            ScreenshotsDrawerSection()
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Project tools").font(OverlayType.title)
            Toggle("Force tools on the next turn", isOn: state.forceTools)
                .disabled(!state.toolAvailability.isAvailable)
            Text(state.toolAvailability.helpText)
                .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
            if let flow = state.activeReasoningFlow, !flow.isEmpty {
                QuickAssistReasoningFlowView(flow: flow)
            } else if let trace = state.activeToolTrace, !trace.isEmpty {
                ForEach(trace.steps) { step in
                    QuickAssistFlowToolRow(
                        step: step, isExpanded: expandedTools.contains(step.id),
                        onToggleExpanded: {
                            if !expandedTools.insert(step.id).inserted { expandedTools.remove(step.id) }
                        }
                    )
                }
            } else {
                Text("No project tool calls for this turn.")
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Review this answer").font(OverlayType.title)
            QuickAssistVerificationStrip(
                model: QuickAssistVerificationStripModel(record: state.verificationRecord, isStreaming: state.isLoading),
                clockStartedAt: nil
            )
            Text("Source and format checks do not establish factual accuracy or execute code.")
                .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
            HStack {
                Button(state.feedbackStatus == .accepted ? "Marked useful" : "Mark useful", action: actions.onAcceptTurn)
                Button(state.feedbackStatus == .rejected ? "Flagged" : "Flag answer", action: actions.onRejectTurn)
            }
            .buttonStyle(.overlay(.secondary))
            .disabled(state.isLoading || state.selectedTurnID == nil || state.interruptedResponse != nil)
            if let recovery = state.recoveryPlan {
                ToneBanner(tone: .warning, title: recovery.title, message: recovery.message)
                ForEach(recovery.actions) { action in
                    Button(action.label) { actions.onApplyRecoveryAction(action) }
                        .buttonStyle(.overlay(.secondary))
                        .disabled(state.isLoading)
                    if let note = action.note {
                        Text(note).font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                    }
                }
            }
            QuickAssistHeaderBadges(
                model: QuickAssistThreadHeaderModel(state: state),
                displayMode: displayMode, isVoiceGuardEnabled: isVoiceGuardEnabled
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("Answer live question", action: actions.onGenerate).disabled(state.isLoading)
                    Button("Follow up", action: actions.onFollowUp).disabled(!state.hasTurns || state.isLoading)
                    Button("New thread", action: actions.onNewThread).disabled(state.isLoading)
                    Button("Add missing facts", action: onFocusQuestion)
                    if let id = state.activeThreadID {
                        Button("Open timeline") { actions.onOpenTimeline(id) }
                    }
                }
                .buttonStyle(.overlay(.ghost))
            }
            Toggle("Show keyboard shortcuts", isOn: $showsKeys)
            if showsKeys { QuickAssistKeyHintRow() }
        }
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let nudge = state.hubNudge {
                ToneBanner(tone: .info, title: nudge.title, message: nudge.message, actions: [
                    BannerAction(title: "Focus question", kind: .secondary, action: onFocusQuestion),
                    BannerAction(title: "Dismiss", kind: .ghost, action: actions.onDismissHubNudge)
                ])
            }
            ForEach(state.coachFindings, id: \.id) { finding in
                ToneBanner(tone: finding.severity == .critical ? .critical : .warning,
                           title: finding.title, message: finding.message, actions: [
                    BannerAction(title: "Use suggestion", kind: .secondary) { actions.onApplyCoachSuggestion(finding.id) },
                    BannerAction(title: "Dismiss", kind: .ghost) { actions.onDismissCoachFinding(finding.id) }
                ])
                if let id = finding.threadId {
                    Button("Open finding timeline") { actions.onOpenTimeline(id) }
                        .buttonStyle(.overlay(.ghost))
                }
            }
            if state.hubNudge == nil && state.coachFindings.isEmpty {
                Text("No coaching suggestions for this turn.")
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        }
    }
}
