import Combine
import Foundation

/// The main window's sidebar sections.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case interview, roles, reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interview: return "Interview"
        case .roles: return "Roles"
        case .reports: return "Reports"
        }
    }

    var systemImage: String {
        switch self {
        case .interview: return "waveform"
        case .roles: return "briefcase"
        case .reports: return "doc.text.magnifyingglass"
        }
    }
}

/// Where the main window is. Menu commands and buttons deep in a screen
/// move between sections through this one object.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var selection: SidebarItem? = .interview
    /// Asks the Roles screen to start a new role.
    @Published var newRoleRequest: UUID?
    /// Asks the Reports screen to show this interview.
    @Published var reportToShow: String?
    /// Asks the Roles screen to select this role (after an import).
    @Published var roleToShow: String?
    /// The interview open in Reports, for File › Print.
    @Published var selectedReportID: String?

    init() {
        // `-InterviewCheckStartSection roles` opens a section at launch
        // (used for screenshots and support).
        if let raw = UserDefaults.standard.string(forKey: "InterviewCheckStartSection"),
           let item = SidebarItem(rawValue: raw) {
            selection = item
        }
    }

    func show(_ item: SidebarItem) { selection = item }

    func requestNewRole() {
        selection = .roles
        newRoleRequest = UUID()
    }

    func showReport(_ interviewID: String?) {
        reportToShow = interviewID
        selection = .reports
    }
}
