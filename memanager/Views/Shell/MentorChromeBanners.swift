import SwiftUI

/// Banners and panes that ride above the active surface on the mentor
/// screen: practice due, the reasoning canvas, live response cards, and
/// the pinned teleprompter line. Renders nothing when none apply.
struct MentorChromeBanners: View {
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var navigator = OverlayNavigator.shared

    private var showsPracticeDue: Bool {
        settings.practiceStudioEnabled && controller.practiceCardsDueCount > 0
    }

    private var showsCanvas: Bool {
        settings.canvasModeEnabled && controller.canvasScene.isNonEmpty
    }

    private var liveCard: ResponseCard? {
        guard settings.hubProactiveNudgesEnabled, !controller.isQuickAssistViewVisible else { return nil }
        return controller.activeLiveResponseCard
    }

    private var pinnedCard: ResponseCard? {
        guard controller.teleprompterModeEnabled else { return nil }
        return controller.teleprompterPinnedResponseCard
    }

    private var hasContent: Bool {
        showsPracticeDue || showsCanvas || liveCard != nil || pinnedCard != nil
    }

    var body: some View {
        if hasContent {
            VStack(spacing: DesignTokens.Spacing.sm) {
                if showsPracticeDue {
                    ToneBanner(
                        tone: .info,
                        message: "\(controller.practiceCardsDueCount) practice cards are due today.",
                        systemImage: "square.stack.3d.up",
                        actions: [BannerAction(title: "Practice", kind: .secondary) { navigator.show(.practice) }]
                    )
                }

                if showsCanvas {
                    CanvasScenePaneView(scene: controller.canvasScene)
                        .frame(maxHeight: 180)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let liveCard {
                    ToneBanner(
                        tone: .warning,
                        title: liveCard.shortLine,
                        message: liveCard.expandedLine,
                        systemImage: "rectangle.stack.badge.person.crop",
                        actions: [
                            BannerAction(title: "Cycle", kind: .ghost) { controller.cycleLiveResponseCard() },
                            BannerAction(title: "Pin", kind: .ghost) { controller.pinActiveResponseCardToTeleprompter() },
                            BannerAction(title: "Refine", kind: .ghost) { controller.refineActiveResponseCard() }
                        ],
                        onDismiss: { controller.dismissLiveResponseCard() }
                    )
                }

                if let pinnedCard {
                    ToneBanner(
                        tone: .success,
                        title: "Pinned line",
                        message: pinnedCard.teleprompterText,
                        systemImage: "text.viewfinder"
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }
}
