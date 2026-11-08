import SwiftUI

/// The one scroll container for a streaming surface. Follows the stream
/// while the reader is near the bottom, offers "Jump to latest" once they
/// scroll away, and scrolls to the top on demand for turn navigation.
struct StreamingTextContainer<Content: View>: View {
    let text: String
    let scrollTarget: ScrollTarget?
    let autoScrollMode: StreamingAutoScrollMode
    let programmaticFollowPolicy: StreamingProgrammaticFollowPolicy
    /// Bump to scroll to the top (turn navigation).
    var scrollToTopNonce: Int? = nil
    /// While streaming the container follows the newest text and offers a
    /// way back to it; a settled answer opens at the top so the opener is
    /// the first thing on screen.
    var isStreaming: Bool = true
    let content: () -> Content

    @State private var isFollowingLatest = true
    @State private var isNearBottom = true
    @State private var isProgrammaticScroll = false
    @State private var programmaticScrollGeneration = 0

    private let bottomAnchorID = "streaming-bottom"
    private let topAnchorID = "streaming-top"
    private let policy = StreamingAutoScrollPolicy()

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let scrollTarget {
                            ScrollViewRegistrar(target: scrollTarget)
                                .frame(width: 0, height: 0)
                        }
                        Color.clear.frame(height: 1).id(topAnchorID)
                        content()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                        StreamingScrollPositionReader { metrics in
                            updateFollowState(using: metrics)
                        }
                        .frame(width: 0, height: 0)
                    }
                    .padding(.horizontal, OverlayLayout.stageInset)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }

                if autoScrollMode == .smart && isStreaming && !isFollowingLatest {
                    Button {
                        isFollowingLatest = true
                        scrollToBottom(proxy, animated: true)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.overlay(.primary, size: .small))
                    .padding(DesignTokens.Spacing.md)
                    .transition(.opacity)
                }
            }
            .onAppear {
                if isStreaming {
                    scrollToBottom(proxy, animated: false)
                } else {
                    isFollowingLatest = false
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                guard streaming else { return }
                isFollowingLatest = true
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: text) { _, _ in
                guard shouldAutoScrollToLatest else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: scrollToTopNonce) { _, nonce in
                guard nonce != nil else { return }
                isFollowingLatest = false
                withAnimation(DesignTokens.Motion.turnSwap) {
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
            }
        }
    }

    private var shouldAutoScrollToLatest: Bool {
        switch autoScrollMode {
        case .always: return true
        case .smart: return isFollowingLatest || isNearBottom
        }
    }

    private func updateFollowState(using metrics: StreamingScrollMetrics) {
        let nearBottom = policy.isNearBottom(
            offsetY: metrics.offsetY,
            visibleHeight: metrics.visibleHeight,
            contentHeight: metrics.contentHeight
        )
        isNearBottom = nearBottom
        let state = reduceStreamingFollowState(
            autoScrollMode: autoScrollMode,
            programmaticFollowPolicy: programmaticFollowPolicy,
            nearBottom: nearBottom,
            isProgrammaticScroll: isProgrammaticScroll,
            isFollowingLatest: isFollowingLatest
        )
        isFollowingLatest = state.isFollowingLatest
        isProgrammaticScroll = state.isProgrammaticScroll
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        programmaticScrollGeneration += 1
        let generation = programmaticScrollGeneration
        isProgrammaticScroll = true
        if animated {
            withAnimation(DesignTokens.Motion.focus) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if programmaticScrollGeneration == generation {
                isProgrammaticScroll = false
            }
        }
    }
}
