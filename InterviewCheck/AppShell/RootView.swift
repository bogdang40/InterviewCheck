import SwiftUI

/// The main window's content: the license / sign-in gate until access is
/// confirmed, then the sidebar layout.
struct RootView: View {
    @ObservedObject private var access = AccessController.shared

    var body: some View {
        Group {
            if TestRuntime.isRunningUnitTests {
                Color.clear
            } else {
                switch access.state {
                case .allowed:
                    MainSplitView()
                case .checking:
                    ProgressView("Checking your license\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .signedOut, .paywall, .unreachable:
                    AccessGateView(controller: access)
                }
            }
        }
    }
}

/// Sidebar (Interview, Roles, Reports) and the selected screen.
struct MainSplitView: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var interview = InterviewController.shared
    @ObservedObject private var permissions = InterviewPermissions.shared
    @ObservedObject private var welcome = WelcomePresenter.shared
    @ObservedObject private var recording = RecordingAnalyzer.shared
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $navigation.selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            switch navigation.selection ?? .interview {
            case .interview:
                InterviewView()
            case .roles:
                RolesView()
            case .reports:
                ReportsView()
            }
        }
        .onAppear {
            // `-InterviewCheckOpenDemo YES` opens the demo at launch (sales demos, screenshots).
            if UserDefaults.standard.bool(forKey: "InterviewCheckOpenDemo") {
                welcome.isPresented = false
                openWindow(id: AppWindowID.demo)
            }
        }
        .sheet(isPresented: $recording.isPresented) {
            AnalyzeRecordingView(analyzer: recording)
        }
        .sheet(isPresented: $welcome.isPresented) {
            WelcomeView(onDone: { welcome.dismiss() })
        }
        .alert(item: $permissions.problem) { problem in
            Alert(title: Text(problem.title), message: Text(problem.message),
                  primaryButton: .default(Text(problem.actionTitle)) { permissions.openSettings(for: problem) },
                  secondaryButton: .cancel())
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        item == .interview && interview.phase == .live ? Text("Live") : nil
    }
}
