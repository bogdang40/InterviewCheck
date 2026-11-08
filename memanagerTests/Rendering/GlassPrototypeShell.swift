import SwiftUI
@testable import memanager

/// Production controls with local sample state and empty actions. This preview
/// neither reads the live session nor changes a draft, route, or focus request.
struct GlassPrototypeShell: View {
    let width: CGFloat
    private let state = QuickAssistRenderFixtures.state(
        isLoading: false, selectedResponse: Self.paymentAnswer,
        streamingDraft: nil, turnCount: 1, provider: .claude,
        answerFamilyBadge: QuickAssistAnswerFamilyBadge(
            familyName: "Concept", frameworkName: "Explain", isProbe: false),
        activeThreadID: "synthetic-glass-preview",
        displayedQuestion: "How do you make payment retries safe?")

    private static let paymentAnswer = """
    **Say first:** I give each operation a request key, so a retry returns the original result.

    ### How it works
    * I store the request key with the operation and its result, so another attempt finds the same payment.
    * I atomically claim a new key before charging, so concurrent retries cannot both start the operation.
    * I compare the request payload on reuse and reject a key attached to a different amount or recipient.

    ### Retention tradeoff
    I retain keys for the supported retry window. After expiry, the same key can represent a new operation, so that limit needs to be explicit.
    """

    var body: some View {
        VStack(spacing: 0) {
            CommandBar(width: width, destination: .live, onSelect: { _ in })
            Hairline()
            HStack {
                Button("Sample workspace") {}.buttonStyle(.overlayGhost)
                Spacer()
                Text("Preview").font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                Button {} label: { Image(systemName: "play.fill") }
                    .buttonStyle(.overlayIcon(size: 30))
            }
            .padding(.horizontal, 22)
            .frame(height: 44)
            Hairline()
            HStack(spacing: 10) {
                SegmentStrip(items: [MentorSurface.assist, .solve, .design].map {
                    SegmentItem(id: $0, title: $0.title, systemImage: $0.systemImage)
                }, selection: .constant(.assist), expandsToFill: true)
                Button {} label: { Label("Context", systemImage: "sidebar.trailing") }
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(.horizontal, 30)
            .frame(height: 50)
            QuickAssistStudioView(state: state, actions: QuickAssistRenderFixtures.actions)
                .background(OverlayPalette.readingSurface.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(OverlayPalette.glassHighlight.opacity(0.85), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            StatusBar(width: width, dotState: .idle, providerName: "Sample answer",
                transcriptCount: 0, screenshotCount: 0, workspaceTitle: nil,
                hints: StatusHintCatalog.hints(surface: .assist, screen: .mentor))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
