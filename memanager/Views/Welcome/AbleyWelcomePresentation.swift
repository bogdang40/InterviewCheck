import SwiftUI

/// The only bridge between account events, the one-shot scene and its dock.
struct AbleyWelcomePresentation: ViewModifier {
    @ObservedObject var access: AccessController
    @ObservedObject private var settings = SettingsManager.shared
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var replayID: UUID?
    @State private var nudgeID: UUID?

    private var requestID: UUID? { isVisible ? (access.welcomeRequestID ?? replayID) : nil }
    private var hasAccount: Bool { access.isAllowed || access.serverSnapshot != nil }
    private var borderWidth: CGFloat {
        CGFloat(settings.configuration(for: settings.borderShaderStyle)?.width ?? 0)
    }

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(requestID == nil)
            .disabled(requestID != nil)
            .accessibilityHidden(requestID != nil)
            .overlay {
                GeometryReader { geometry in
                    if hasAccount, requestID == nil {
                        Button {
                            guard nudgeID == nil else { return }
                            if reduceMotion { replayID = UUID() }
                            else { nudgeID = UUID() }
                        } label: {
                            Image("AbleyLogo")
                                .resizable().scaledToFit()
                                .frame(width: AbleyWelcomeMotion.dockSize, height: AbleyWelcomeMotion.dockSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(nudgeID == nil ? 1 : 1.24)
                        .animation(.spring(response: 0.22, dampingFraction: 0.48), value: nudgeID)
                        .help("Replay Abley's welcome")
                        .accessibilityLabel("Replay Abley's welcome")
                        .accessibilityIdentifier("abley.welcome.replay")
                        .position(access.isAllowed
                            ? AbleyWelcomeMotion.dockCenter(in: geometry.size, borderWidth: borderWidth)
                            : CGPoint(x: 32, y: 29))
                    }
                    if let requestID {
                        AbleyWelcomeAnimation(borderWidth: borderWidth) { finish(requestID) }
                            .id(requestID)
                    }
                }
            }
            .onChange(of: isVisible) { _, visible in
                if !visible {
                    replayID = nil
                    nudgeID = nil
                    if let requestID = access.welcomeRequestID {
                        access.completeWelcome(requestID: requestID)
                    }
                }
            }
            .onChange(of: hasAccount) { _, hasAccount in
                if !hasAccount { replayID = nil; nudgeID = nil }
            }
            .onChange(of: access.welcomeRequestID) { _, requestID in
                if requestID != nil { replayID = nil; nudgeID = nil }
            }
            .task(id: nudgeID) {
                guard let nudgeID else { return }
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch { return }
                guard !Task.isCancelled, isVisible, hasAccount, self.nudgeID == nudgeID else { return }
                replayID = nudgeID
                self.nudgeID = nil
            }
    }

    private func finish(_ requestID: UUID) {
        if replayID == requestID { replayID = nil }
        access.completeWelcome(requestID: requestID)
    }
}
