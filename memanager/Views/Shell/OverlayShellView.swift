import SwiftUI

/// Persistent destination hosts preserve drafts and selections across navigation.
/// Native glass uses the same bounds, leaving the spaces between panes clear.
struct OverlayShellView: View {
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var audioService = AudioCaptureService.shared
    @ObservedObject private var screenshotService = ScreenshotService.shared
    @ObservedObject private var navigator = OverlayNavigator.shared
    @ObservedObject private var workspaceStore = WorkspaceStore.shared
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.overlayContentIsVisible) private var isContentVisible
    @State private var visitedScreens: Set<OverlayScreen> = [.mentor]
    @State private var lastSolveSection: MentorResponse.Section = .problem
    @State private var drawerVisible = false
    let width: CGFloat

    private var surface: MentorSurface {
        MentorSurfaceResolver(isQuickAssistVisible: controller.isQuickAssistViewVisible,
            isTranscriptVisible: controller.isTranscriptViewVisible,
            currentSection: controller.currentSection).surface
    }
    /// The interview screens always keep the utility dock below them.
    private var assistOwnsDock: Bool { false }
    private var borderWidth: CGFloat {
        CGFloat(settings.configuration(for: settings.borderShaderStyle)?.width ?? 0)
    }
    private var pillModel: SessionPillModel {
        SessionPillModel(state: controller.session.state, isRecording: audioService.isRecording,
                        isLoading: controller.isLoading, isStreaming: controller.isStreaming)
    }

    var body: some View {
        GeometryReader { proxy in
            let plan = FloatingShellGeometry(size: CGSize(width: width, height: proxy.size.height), borderWidth: borderWidth)
            shell(plan)
                .sheet(isPresented: Binding(
                    get: { drawerVisible && navigator.isShowingMentor && !drawerFits(plan) },
                    set: { isPresented in
                        // A resize or route change may dismiss a sheet without
                        // cancelling the user's requested context visibility.
                        if navigator.isShowingMentor && !drawerFits(plan) { drawerVisible = isPresented }
                    }
                )) {
                    ContextDrawer(onClose: { drawerVisible = false })
                        .frame(width: min(max(plan.content.width - 24, 350), 600), height: 540)
                }
        }
        .onAppear { visitedScreens.insert(navigator.screen); rememberSolveSection(controller.currentSection) }
        .onChange(of: navigator.screen) { _, screen in visitedScreens.insert(screen) }
        .onChange(of: controller.currentSection) { _, section in rememberSolveSection(section) }
        .onChange(of: controller.isPracticeStudioVisible) { _, visible in
            guard visible else { return }
            controller.isPracticeStudioVisible = false
            navigator.show(.practice)
        }
    }

    private func shell(_ plan: FloatingShellGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            AbleyNavigationRail(width: plan.navigation.width, isCompact: plan.isCompact,
                                destination: navigator.destination, onSelect: navigator.select)
                .frame(width: plan.navigation.width, height: plan.navigation.height)
                .position(x: plan.navigation.midX, y: plan.navigation.midY)

            workspace(plan)
                .frame(width: plan.workspace.width,
                       height: assistOwnsDock ? plan.workspace.height : plan.content.height)
                .position(x: plan.workspace.midX,
                          y: assistOwnsDock ? plan.workspace.midY : plan.content.midY)

            if !assistOwnsDock {
                utilityDock(width: plan.dock.width)
                    .frame(width: plan.dock.width, height: plan.dock.height)
                    .position(x: plan.dock.midX, y: plan.dock.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(FloatingShellForegroundShape(geometry: plan))
    }

    private func workspace(_ plan: FloatingShellGeometry) -> some View {
        let hasDrawer = navigator.isShowingMentor && drawerVisible && drawerFits(plan)
        let stageWidth = plan.content.width - (hasDrawer ? OverlayLayout.drawerWidth + 1 : 0)
        return VStack(spacing: 0) {
            header(width: plan.content.width)
            Hairline().padding(.horizontal, 20)
            errorBanners
            HStack(spacing: 0) {
                ZStack {
                    ForEach(OverlayScreen.allCases.filter { visitedScreens.contains($0) || navigator.screen == $0 }) { screen in
                        destinationHost(screen, width: stageWidth)
                            .environment(\.floatingDockLayout, screen == .mentor && assistOwnsDock
                                ? FloatingDockLayout(height: plan.dock.height, gap: plan.dockGap) : nil)
                            .environment(\.overlayContentIsVisible, isContentVisible && navigator.screen == screen)
                            .opacity(navigator.screen == screen ? 1 : 0)
                            .allowsHitTesting(navigator.screen == screen)
                            .disabled(navigator.screen != screen)
                            .accessibilityHidden(navigator.screen != screen)
                            .zIndex(navigator.screen == screen ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hasDrawer {
                    Hairline(axis: .vertical)
                    ContextDrawer(onClose: { drawerVisible = false })
                        .frame(width: OverlayLayout.drawerWidth)
                }
            }
        }
    }

    private func header(width: CGFloat) -> some View {
        let horizontal = width >= 620
        let layout = horizontal ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        return layout {
            localNavigation
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if !horizontal { Spacer(minLength: 0) }
                SessionStatePill(model: pillModel, startedAt: controller.session.startedAt, actions: sessionActions)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(Capsule().stroke(OverlayPalette.hairline.opacity(0.45), lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: horizontal ? 68 : 96)
    }

    @ViewBuilder private var localNavigation: some View {
        HStack {
            Text(navigator.destination.heading)
                .font(OverlayType.heading).foregroundStyle(OverlayPalette.textPrimary)
            Spacer(minLength: 0)
            if navigator.destination == .settings {
                Button("Done") { navigator.toggle(.settings) }
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
        }
        .frame(height: 40)
    }

    private func utilityDock(width: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button { navigator.show(.workspaces) } label: {
                    Label(workspaceStore.activeWorkspace.map { "Role: \($0.displayTitle)" } ?? "Choose a role",
                          systemImage: "briefcase")
                        .lineLimit(1)
                }
                .help("The role whose job description and prompts the interview uses.")
                Spacer(minLength: 0)
                if !navigator.isShowingMentor {
                    Button("Interview", systemImage: "waveform.path") { navigator.returnToMentor() }
                }
            }
            .buttonStyle(.overlay(.ghost, size: .small))
            .padding(.horizontal, 12)
            StatusBar(width: width, dotState: pillModel.dotState,
                providerName: controller.currentProviderDisplayName,
                transcriptCount: audioService.transcriptEntries.count,
                screenshotCount: screenshotService.screenshots.count, workspaceTitle: nil,
                hints: StatusHintCatalog.hints(surface: surface, screen: navigator.screen),
                keyboardStatus: navigator.isShowingMentor ? controller.overlayKeyboardStatus : nil)
        }
    }

    @ViewBuilder private func destinationHost(_ screen: OverlayScreen, width: CGFloat) -> some View {
        if screen == .mentor { InterviewScreen(width: width) }
        else if screen == .history { InterviewReportsScreen(width: width) }
        else { OverlayScreenHost(screen: screen) }
    }

    @ViewBuilder private var errorBanners: some View {
        let messages = [audioService.errorMessage, controller.errorMessage].compactMap { $0 }
        if !messages.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    ToneBanner(tone: .warning, message: message)
                }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    private func drawerFits(_ plan: FloatingShellGeometry) -> Bool {
        !assistOwnsDock && OverlayLayout.drawerFits(in: plan.content.width)
    }

    private var sessionActions: SessionPillActions {
        SessionPillActions(start: { navigator.returnToMentor() }, pauseOrResume: { controller.togglePauseSession() },
            end: { InterviewController.shared.end() }, reset: {},
            screenshot: { screenshotService.captureFullScreen() })
    }

    private func select(_ surface: MentorSurface) {
        switch surface {
        case .assist: controller.showQuickAssist(clearInputs: false)
        case .solve: controller.selectSection(lastSolveSection)
        case .design: controller.selectSection(.systemDesign)
        case .transcript: controller.showTranscriptLog()
        }
    }

    private func rememberSolveSection(_ section: MentorResponse.Section) {
        if section != .systemDesign { lastSolveSection = section }
    }
}
