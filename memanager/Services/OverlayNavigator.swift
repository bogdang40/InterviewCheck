import Combine
import Foundation

/// The seam session code uses to bring the overlay back to the mentor
/// surface without depending on the concrete navigator.
@MainActor
protocol OverlayNavigating: AnyObject {
    func show(_ screen: OverlayScreen)
    func returnToMentor()
}

/// Owns which top level screen the overlay is showing. Deliberately tiny:
/// the mentor surface keeps its own state in SessionController, and this
/// object only decides whether that surface or one of the full screens
/// (Workspaces, Knowledge, Settings) is on screen.
@MainActor
final class OverlayNavigator: ObservableObject, OverlayNavigating {
    static let shared = OverlayNavigator()

    @Published private(set) var screen: OverlayScreen = .mentor
    @Published var settingsPane: SettingsPane = .aiProvider
    private(set) var lastPreparationScreen: OverlayScreen = .workspaces
    private(set) var settingsReturnScreen: OverlayScreen = .mentor

    init(screen: OverlayScreen = .mentor) {
        self.screen = screen
        if OverlayDestination(screen: screen) == .prepare { lastPreparationScreen = screen }
    }

    var isShowingMentor: Bool { screen == .mentor }

    func show(_ screen: OverlayScreen) {
        guard self.screen != screen else { return }
        if screen == .settings { settingsReturnScreen = self.screen }
        if OverlayDestination(screen: screen) == .prepare { lastPreparationScreen = screen }
        self.screen = screen
    }

    var destination: OverlayDestination { OverlayDestination(screen: screen) }

    func select(_ destination: OverlayDestination) {
        switch destination {
        case .live: show(.mentor)
        case .prepare: show(lastPreparationScreen)
        case .review: show(.history)
        case .settings: show(.settings)
        }
    }

    func showSettings(_ pane: SettingsPane) {
        settingsPane = pane
        show(.settings)
    }

    /// Header buttons toggle: picking the screen that is already up returns
    /// to the mentor surface, so one control both opens and closes it.
    func toggle(_ screen: OverlayScreen) {
        if self.screen == screen {
            show(screen == .settings ? settingsReturnScreen : .mentor)
        } else {
            show(screen)
        }
    }

    func returnToMentor() {
        show(.mentor)
    }
}
