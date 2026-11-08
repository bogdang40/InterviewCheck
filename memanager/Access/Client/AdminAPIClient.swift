import Foundation

protocol AdminAPIClienting {
    func stats(token: String) async throws -> AdminStats
    func users(token: String, query: String?, cursor: String?) async throws -> AdminUserPage
    func update(token: String, userID: String, patch: AdminUserPatch) async throws -> AdminUserView
    func audit(token: String) async throws -> [AdminAuditEntry]
}

/// Thin admin surface reusing the account client's plumbing.
final class AdminAPIClient: AdminAPIClienting {
    private let client: AccessAPIClient

    init(client: AccessAPIClient = AccessAPIClient()) {
        self.client = client
    }

    func stats(token: String) async throws -> AdminStats {
        try await client.perform(.adminStats, token: token)
    }

    func users(token: String, query: String?, cursor: String?) async throws -> AdminUserPage {
        try await client.perform(.adminUsers(query: query, cursor: cursor), token: token)
    }

    func update(token: String, userID: String, patch: AdminUserPatch) async throws -> AdminUserView {
        try await client.perform(.adminPatch(userID: userID, patch: patch), token: token)
    }

    func audit(token: String) async throws -> [AdminAuditEntry] {
        let page: AdminAuditPage = try await client.perform(.adminAudit(), token: token)
        return page.entries
    }
}
