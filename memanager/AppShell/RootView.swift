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
                        .background(OverlayPalette.backdropBase)
                }
            }
        }
    }
}

/// Sidebar (Interview, Roles, Reports) and the selected screen.
struct MainSplitView: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var interview = InterviewController.shared
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
    }

    private func badge(for item: SidebarItem) -> Text? {
        item == .interview && interview.phase == .live ? Text("Live") : nil
    }
}
