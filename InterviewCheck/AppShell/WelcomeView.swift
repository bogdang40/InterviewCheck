import AppKit
import SwiftUI

/// First launch: what the app does and the three steps to a first
/// interview, each with its state and a button that goes there.
struct WelcomeView: View {
    @ObservedObject private var roles = RoleStore.shared
    @ObservedObject private var keys = SettingsManager.shared
    @Environment(\.openWindow) private var openWindow
    let onDone: () -> Void

    private var hasKeys: Bool { DetectorReadiness.current().problems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to \(AppBrand.name)").font(.title.weight(.semibold))
                    Text("Notice when a candidate reads answers from an AI tool.")
                        .foregroundStyle(.secondary)
                }
            }

            step(1, done: hasKeys, title: "Add your keys",
                 detail: "Deepgram times every answer word by word. A Claude or OpenAI key writes the AI answers to compare against.") {
                SettingsLink { Text("Open Settings") }
            }
            step(2, done: !roles.roles.isEmpty, title: "Create a role",
                 detail: "Paste the job description. Draft writes interview questions and the prompts a cheating tool would use for this job.") {
                Button("New Role") {
                    AppNavigation.shared.requestNewRole()
                    onDone()
                }
            }
            step(3, done: !ConnectorManager.shared.accounts.isEmpty, title: "Connect your calendar or ATS (optional)",
                 detail: "Upcoming interviews appear with the candidate, job description and r\u{00E9}sum\u{00E9} ready, and recordings come in for scoring.") {
                Button("Open Connections") {
                    AppNavigation.shared.show(.connections)
                    onDone()
                }
            }
            step(4, done: false, title: "Run the interview",
                 detail: "Tell the candidate the interview is checked, then press Question Asked (\u{21E7}\u{2318}\u{21A9}) after each question, even with the call in front.") {
                EmptyView()
            }

            Text("A score is a signal to follow up on, never proof. Ask a follow-up before deciding.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Watch a Demo Interview") {
                    openWindow(id: AppWindowID.demo)
                    onDone()
                }
                .help("A scripted interview through the real detector. No keys or microphone needed.")
                Spacer()
                Button("Get Started", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func step<Action: View>(_ number: Int, done: Bool, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 2)
            }
        }
    }
}

/// Shows the welcome once, and again from Help > Welcome to InterviewCheck.
@MainActor
final class WelcomePresenter: ObservableObject {
    static let shared = WelcomePresenter()
    private static let seenKey = "interviewcheck.hasSeenWelcome"

    @Published var isPresented: Bool

    init(defaults: UserDefaults = AppDefaults.standard) {
        isPresented = !TestRuntime.isRunningUnitTests && !defaults.bool(forKey: Self.seenKey)
    }

    func dismiss() {
        isPresented = false
        AppDefaults.standard.set(true, forKey: Self.seenKey)
    }

    func show() { isPresented = true }
}
