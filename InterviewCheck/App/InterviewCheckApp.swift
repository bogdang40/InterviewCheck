import AppKit
import SwiftUI

/// A normal Mac app: one main window with a sidebar, a Settings window
/// (Cmd+,), an optional Live Companion window, and a full menu bar.
@main
struct InterviewCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var interview = InterviewController.shared

    var body: some Scene {
        WindowGroup(AppBrand.name, id: AppWindowID.main) {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { AppCommands() }

        Window("Live Companion", id: AppWindowID.companion) {
            LiveCompanionView()
                .frame(minWidth: 320, minHeight: 260)
        }
        .defaultSize(width: 380, height: 460)
        .defaultPosition(.topTrailing)

        Settings {
            AppSettingsView()
        }

        MenuBarExtra(isInserted: Binding(get: { interview.phase == .live }, set: { _ in })) {
            LiveMenuBarContent(controller: interview)
        } label: {
            LiveMenuBarLabel(controller: interview)
        }
    }
}

enum AppWindowID {
    static let main = "main"
    static let companion = "companion"
}
