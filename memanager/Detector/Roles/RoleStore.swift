import Combine
import Foundation

/// All roles, kept in the app database. The selected role is the one the
/// next interview uses.
@MainActor
final class RoleStore: ObservableObject {
    static let shared = RoleStore()

    @Published private(set) var roles: [RoleProfile] = []
    @Published var selectedRoleID: String? {
        didSet { defaults.set(selectedRoleID, forKey: Self.selectedKey) }
    }

    private let database: SessionDatabase
    private let defaults: UserDefaults
    private static let selectedKey = "interviewcheck.selectedRoleID"

    init(database: SessionDatabase = .shared, defaults: UserDefaults = AppDefaults.standard) {
        self.database = database
        self.defaults = defaults
        selectedRoleID = defaults.string(forKey: Self.selectedKey)
        reload()
    }

    var selectedRole: RoleProfile? { roles.first { $0.id == selectedRoleID } }

    func role(id: String?) -> RoleProfile? {
        guard let id else { return nil }
        return roles.first { $0.id == id }
    }

    func reload() {
        roles = database.loadRoleProfiles().sorted { $0.updatedAt > $1.updatedAt }
        if let selectedRoleID, !roles.contains(where: { $0.id == selectedRoleID }) {
            self.selectedRoleID = roles.first?.id
        }
    }

    @discardableResult
    func create(name: String = "", company: String = "") -> RoleProfile {
        let role = RoleProfile(name: name, company: company)
        save(role)
        if selectedRoleID == nil { selectedRoleID = role.id }
        return role
    }

    func save(_ role: RoleProfile) {
        var updated = role
        updated.updatedAt = Date()
        database.saveRoleProfile(updated)
        if let index = roles.firstIndex(where: { $0.id == updated.id }) {
            roles[index] = updated
        } else {
            roles.insert(updated, at: 0)
        }
    }

    func delete(_ id: String) {
        database.deleteRoleProfile(workspaceID: id)
        roles.removeAll { $0.id == id }
        if selectedRoleID == id { selectedRoleID = roles.first?.id }
    }
}
