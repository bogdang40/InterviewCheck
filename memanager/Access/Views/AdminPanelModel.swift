import Combine
import Foundation

/// Keeps the last successful page on failures and isolates pending account changes.
@MainActor
final class AdminPanelModel: ObservableObject {
    @Published private(set) var users: [AdminUserView] = []
    @Published private(set) var stats: AdminStats?
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var updatingUserIDs: Set<String> = []
    @Published private(set) var messageIsError = false
    @Published var query = ""
    @Published var message: String?

    private let client: AdminAPIClienting
    private let tokenProvider: @MainActor () -> String?
    private var loadID = UUID()
    private var loadedQuery = ""

    init(client: AdminAPIClienting = AdminAPIClient(), tokenProvider: @escaping @MainActor () -> String? = { AccessController.shared.token }) {
        self.client = client
        self.tokenProvider = tokenProvider
    }

    func load(reset: Bool = true) async {
        guard let token = tokenProvider() else {
            loadID = UUID()
            users = []
            stats = nil
            nextCursor = nil
            isLoading = false
            message = "Sign in on the Account page to manage server accounts."
            messageIsError = false
            return
        }
        guard reset || (!isLoading && nextCursor != nil) else { return }
        if reset { loadID = UUID() }
        let requestID = loadID
        let search = reset ? query.trimmingCharacters(in: .whitespacesAndNewlines) : loadedQuery
        isLoading = true
        defer { if requestID == loadID { isLoading = false } }
        do {
            if reset {
                async let statsTask = client.stats(token: token)
                async let pageTask = client.users(token: token, query: search.isEmpty ? nil : search, cursor: nil)
                let (stats, page) = try await (statsTask, pageTask)
                guard requestID == loadID, tokenProvider() == token else { return }
                self.stats = stats
                users = page.users
                nextCursor = page.nextCursor
                loadedQuery = search
            } else if let cursor = nextCursor {
                let page = try await client.users(token: token, query: search.isEmpty ? nil : search, cursor: cursor)
                guard requestID == loadID, tokenProvider() == token else { return }
                let knownIDs = Set(users.map(\.id))
                users += page.users.filter { !knownIDs.contains($0.id) }
                nextCursor = page.nextCursor
            }
            message = nil
            messageIsError = false
        } catch {
            guard requestID == loadID, tokenProvider() == token else { return }
            message = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
            messageIsError = true
        }
    }

    func apply(_ patch: AdminUserPatch, to user: AdminUserView) async {
        guard !updatingUserIDs.contains(user.id), let token = tokenProvider() else { return }
        updatingUserIDs.insert(user.id)
        defer { updatingUserIDs.remove(user.id) }
        do {
            let updated = try await client.update(token: token, userID: user.id, patch: patch)
            guard tokenProvider() == token else { return }
            if let index = users.firstIndex(where: { $0.id == updated.id }) { users[index] = updated }
            message = "Updated \(updated.user.email)."
            messageIsError = false
            do {
                let refreshed = try await client.stats(token: token)
                guard tokenProvider() == token else { return }
                stats = refreshed
            } catch {
                message = "Updated \(updated.user.email). Statistics could not be refreshed: \(error.localizedDescription)"
                messageIsError = true
            }
        } catch {
            guard tokenProvider() == token else { return }
            message = (error as? AccessAPIError)?.errorDescription ?? error.localizedDescription
            messageIsError = true
        }
    }

    func grant(days: Int, to user: AdminUserView) async {
        guard let until = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return }
        await apply(AdminUserPatch(complimentaryUntil: .some(until)), to: user)
    }

    func clearGrant(for user: AdminUserView) async {
        await apply(AdminUserPatch(complimentaryUntil: .some(nil)), to: user)
    }

    func setRole(_ role: AccountRole, for user: AdminUserView) async {
        await apply(AdminUserPatch(role: role), to: user)
    }

    func setDisabled(_ disabled: Bool, for user: AdminUserView) async {
        await apply(AdminUserPatch(disabled: disabled), to: user)
    }
}
