import SwiftUI

/// The answer. Owns the one persistent scroll container across loading,
/// streaming, and settled phases, the verification strip, the answer
/// clock, and the empty state.
struct QuickAssistStage: View {
    let state: QuickAssistStudioState
    let actions: QuickAssistStudioActions
    let plan: QuickAssistStudioLayoutPlan
    let fontSize: CGFloat

    /// Scroll to top fires on turn navigation, never at stream settle, so the
    /// reader keeps their place when the styled answer replaces the draft.
    @State private var scrollToTopNonce = 0
    @State private var lastRenderSeed: String?
    @State private var seedChangeCameFromStream = false
    @State private var clock = QuickAssistAnswerClockState.idle

    private var readingWidth: CGFloat {
        plan.readingWidth - (plan.breakpoint == .compact ? 0 : 48)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let interruption = state.interruptionMessage {
                ToneBanner(tone: .neutral, title: interruption, message: "Partial answer retained without saving a completed turn. Select a turn to return to its saved answer.")
                    .padding(.horizontal, OverlayLayout.stageInset)
            }
            if state.isUpdatingPreviousResult {
                ToneBanner(
                    tone: .info,
                    title: "Updating previous result",
                    message: "The current answer stays readable until the new one starts streaming.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .padding(.horizontal, OverlayLayout.stageInset)
                .padding(.top, DesignTokens.Spacing.sm)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: state.shouldRenderStreamingDraft) { _, isStreamingNow in
            if isStreamingNow { seedChangeCameFromStream = true }
        }
        .onChange(of: state.responseRenderSeed) { _, newSeed in
            clock = clock.turnChanged(to: newSeed)
            defer { lastRenderSeed = newSeed }
            guard newSeed != nil, newSeed != lastRenderSeed else { return }
            if seedChangeCameFromStream {
                seedChangeCameFromStream = false
                return
            }
            scrollToTopNonce += 1
        }
        .onChange(of: state.isLoading) { wasLoading, isLoading in
            clock = clock.loadingChanged(
                wasLoading: wasLoading,
                isLoading: isLoading,
                hasResponse: state.responseForDisplay != nil,
                seed: state.responseRenderSeed,
                now: Date()
            )
        }
    }

    /// Drives the container's follow the stream auto scroll.
    private var scrollRevisionText: String {
        if state.shouldRenderStreamingDraft, let draft = state.streamingDraft {
            return draft
        }
        return state.responseForDisplay ?? ""
    }

    @ViewBuilder
    private var content: some View {
        if state.showsStage {
            StreamingTextContainer(
                text: scrollRevisionText,
                scrollTarget: .quickAssist,
                autoScrollMode: .smart,
                programmaticFollowPolicy: .allowUserDetachment,
                scrollToTopNonce: scrollToTopNonce,
                isStreaming: state.shouldRenderStreamingDraft
            ) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    questionHeading
                    answer
                }
                .padding(.vertical, DesignTokens.Spacing.lg)
                .frame(maxWidth: readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            QuickAssistStageEmptyState(onGenerate: actions.onGenerate, onFocusQuestion: actions.onFocusQuestion)
        }
    }

    @ViewBuilder
    private var answer: some View {
        if state.shouldRenderStreamingDraft, let draft = state.streamingDraft {
            QuickAssistStreamingResponseView(
                draft: draft,
                fontSize: fontSize,
                renderSeed: state.responseRenderSeed,
                textColumnMaxWidth: readingWidth,
                mermaidHeight: 420,
                frameworkName: state.frameworkName
            )
        } else if let response = state.responseForDisplay {
            QuickAssistStyledResponseView(
                text: response,
                fontSize: fontSize,
                markdownRenderMode: .preserveWhitespace,
                renderSeed: state.responseRenderSeed,
                textColumnMaxWidth: readingWidth,
                mermaidHeight: 420,
                mermaidStaggered: true,
                frameworkName: state.frameworkName
            )
        } else if state.activeReasoningFlow?.isEmpty ?? true {
            QuickAssistLoadingSkeleton(fontSize: fontSize)
        }
    }

    @ViewBuilder private var questionHeading: some View {
        let question = (state.displayedQuestion ?? state.question.wrappedValue).trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(state.shouldRenderStreamingDraft ? "Answering" : "Asked")
                    .font(OverlayType.captionStrong)
                    .foregroundStyle(OverlayPalette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(OverlayPalette.accentTint, in: Capsule())
                Text(question)
                    .font(OverlayType.body(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(OverlayPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OverlayPalette.hairline, lineWidth: 1))
        }
    }
}
