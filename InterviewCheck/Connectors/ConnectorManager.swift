import AppKit
import Combine
import Foundation
import InterviewCheckConnectors

/// The connected systems, their sync state, and the upcoming interviews and
/// recordings they bring in. Credentials live in the Keychain; synced items
/// in the app database.
@MainActor
final class ConnectorManager: ObservableObject {
    static let shared = ConnectorManager()

    struct Account: Codable, Equatable, Identifiable {
        let kind: ConnectorKind
        var label: String
        var connectedAt: Date
        var lastSync: Date?
        var lastError: String?
        /// Recordings were fetched up to here (moves only on success).
        var recordingsCheckedAt: Date?
        var id: String { kind.rawValue }
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var upcoming: [ExternalInterview] = []
    @Published private(set) var recordings: [(recording: ExternalRecording, interviewID: String?)] = []
    @Published private(set) var syncing: Set<ConnectorKind> = []

    let store: CredentialStore
    let database: SessionDatabase
    let defaults: UserDefaults
    var transport: HTTPTransport = URLSession.shared
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Builds connectors; tests swap in fakes.
    var factory: (ConnectorKind, ConnectorCredentials, HTTPTransport, AccessTokenProvider?) throws -> Connector = {
        try ConnectorFactory.make($0, credentials: $1, transport: $2, accessToken: $3)
    }
    var now: () -> Date = { Date() }
    private var timer: Timer?
    /// One token session per account, shared by every connector built for
    /// it, so refreshes never race.
    var sessions: [ConnectorKind: OAuthSession] = [:]
    /// Bumped by each Prepare; an older one still running stops writing.
    var prepareGeneration = 0
    /// Called with the upcoming list after every change (reminders).
    var onUpcomingChanged: (([ExternalInterview]) -> Void)?
    /// Called after a sync that may have brought new recordings.
    var onSynced: (() -> Void)?
    private static let accountsKey = "interviewcheck.connectors.accounts"
    static let syncInterval: TimeInterval = 15 * 60

    init(store: CredentialStore = KeychainCredentialStore(service: "com.interviewcheck.connectors"),
         database: SessionDatabase = .shared, defaults: UserDefaults = AppDefaults.standard) {
        self.store = store
        self.database = database
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        reloadCache()
    }

    func account(_ kind: ConnectorKind) -> Account? { accounts.first { $0.kind == kind } }
    var isSyncing: Bool { !syncing.isEmpty }

    // MARK: - Connecting

    /// Saves typed credentials, checks them with one call, then syncs.
    func connect(_ kind: ConnectorKind, fields: [String: String]) async throws {
        let credentials = ConnectorCredentials(fields: fields)
        let connector = try factory(kind, credentials, transport, nil)
        let label = try await connector.verify()
        try store.save(credentials, for: kind.rawValue)
        sessions[kind] = nil
        upsert(Account(kind: kind, label: label, connectedAt: now()))
        await sync(kind)
    }

    /// Browser sign-in for OAuth connectors (Google, Microsoft, Zoom).
    func signIn(_ kind: ConnectorKind, fields: [String: String]) async throws {
        guard case .oauth(var provider, _) = kind.descriptor.auth else { return }
        let clientID = fields["clientID"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !clientID.isEmpty else { throw ConnectorError.missingCredential("client ID") }
        if kind == .microsoft365 { provider = MicrosoftConnectorProvider.provider(ConnectorCredentials(fields: fields)) }
        let client = OAuthClient(provider: provider, clientID: clientID, clientSecret: fields["clientSecret"], transport: transport)
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let redirect = try await receiver.start(host: kind == .microsoft365 ? "localhost" : "127.0.0.1")
        let verifier = PKCE.verifier()
        let state = UUID().uuidString
        openURL(client.authorizationURL(redirectURI: redirect, state: state, codeChallenge: PKCE.challenge(for: verifier)))
        let callback = try await receiver.waitForCallback()
        let code = try LoopbackReceiver.code(from: callback, expectedState: state)
        let tokens = try await client.exchange(code: code, verifier: verifier, redirectURI: redirect)
        let credentials = ConnectorCredentials(fields: fields, tokens: tokens)
        try store.save(credentials, for: kind.rawValue)
        sessions[kind] = nil
        let connector = try makeConnector(kind)
        let label = try await connector.verify()
        upsert(Account(kind: kind, label: label, connectedAt: now()))
        await sync(kind)
    }

    /// Saved settings without secrets, to prefill a "Fix Connection" form.
    func storedFields(_ kind: ConnectorKind) -> [String: String] {
        guard let saved = store.load(kind.rawValue) else { return [:] }
        let secrets: Set<String>
        switch kind.descriptor.auth {
        case .fields(let list): secrets = Set(list.filter(\.isSecret).map(\.key))
        case .oauth(_, let list): secrets = Set(list.filter(\.isSecret).map(\.key))
        case .mcp: secrets = ["token"]
        case .system: secrets = []
        }
        return saved.fields.filter { !secrets.contains($0.key) }
    }

    /// Secret fields left empty in a fix-up form keep their saved value.
    func mergedWithSavedSecrets(_ kind: ConnectorKind, _ fields: [String: String]) -> [String: String] {
        guard let saved = store.load(kind.rawValue) else { return fields }
        return saved.fields.merging(fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) { _, new in new }
    }

    var accountsNeedingAttention: Int { accounts.filter { $0.lastError != nil }.count }

    func disconnect(_ kind: ConnectorKind) {
        sessions[kind] = nil
        store.delete(kind.rawValue)
        accounts.removeAll { $0.kind == kind }
        saveAccounts()
        database.deleteExternalData(source: kind)
        reloadCache()
    }

    /// The live connector for a connected account, with token refresh.
    func makeConnector(_ kind: ConnectorKind) throws -> Connector {
        guard let credentials = store.load(kind.rawValue) ?? (kind == .appleCalendar ? ConnectorCredentials() : nil) else {
            throw ConnectorError.notConnected
        }
        var tokenProvider: AccessTokenProvider?
        var oauthProvider: OAuthProvider?
        switch kind.descriptor.auth {
        case .oauth(let provider, _): oauthProvider = kind == .microsoft365 ? MicrosoftConnectorProvider.provider(credentials) : provider
        case .mcp: oauthProvider = Self.mcpProvider(credentials)
        default: break
        }
        if let provider = oauthProvider, let tokens = credentials.tokens {
            let session = sessions[kind] ?? {
                let client = OAuthClient(provider: provider, clientID: credentials["clientID"] ?? "",
                                         clientSecret: credentials["clientSecret"], transport: transport)
                let store = self.store
                let session = OAuthSession(tokens: tokens, client: client) { updated in
                    // Not after a disconnect: the account is gone for good.
                    guard var saved = store.load(kind.rawValue) else { return }
                    saved.tokens = updated
                    try? store.save(saved, for: kind.rawValue)
                }
                sessions[kind] = session
                return session
            }()
            tokenProvider = { try await session.accessToken() }
        }
        return try factory(kind, credentials, transport, tokenProvider)
    }

    // MARK: - Syncing

    func syncAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts { group.addTask { await self.sync(account.kind) } }
        }
    }

    func sync(_ kind: ConnectorKind) async {
        guard account(kind) != nil, !syncing.contains(kind) else { return }
        syncing.insert(kind)
        defer { syncing.remove(kind) }
        var failures: [String] = []
        var recordingsCheckedAt: Date?
        let started = now()
        do {
            let connector = try makeConnector(kind)
            // Interviews and recordings are fetched separately: one failing
            // (a missing scope, say) must not stop the other.
            if let source = connector as? InterviewSource {
                do {
                    // A week back too, so finished interviews can be matched to recordings.
                    let found = try await source.upcomingInterviews(from: started.addingTimeInterval(-7 * 86_400),
                                                                     to: started.addingTimeInterval(14 * 86_400))
                    // Disconnected while waiting: keep nothing.
                    guard account(kind) != nil else { return }
                    database.replaceExternalInterviews(found, source: kind)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if let source = connector as? RecordingSource {
                do {
                    let since = account(kind)?.recordingsCheckedAt?.addingTimeInterval(-86_400)
                        ?? started.addingTimeInterval(-7 * 86_400)
                    let found = try await source.recordings(since: since)
                    guard account(kind) != nil else { return }
                    database.addExternalRecordings(found)
                    recordingsCheckedAt = started
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        if var updated = account(kind) {
            updated.lastSync = now()
            updated.lastError = failures.isEmpty ? nil : failures.joined(separator: " ")
            if let recordingsCheckedAt { updated.recordingsCheckedAt = recordingsCheckedAt }
            upsert(updated)
        }
        reloadCache()
        onSynced?()
    }

    func startAutoSync() {
        timer?.invalidate()
        // Coming back to the app re-checks when the last sync is stale.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let manager = ConnectorManager.shared
                let stale = manager.accounts.contains { ($0.lastSync ?? .distantPast) < manager.now().addingTimeInterval(-5 * 60) }
                if stale { await manager.syncAll() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { _ in
            Task { @MainActor in await ConnectorManager.shared.syncAll() }
        }
        if !accounts.isEmpty { Task { await syncAll() } }
    }

    /// Adds the interviews in a dropped .ics invite.
    func importInvite(_ url: URL) throws -> [ExternalInterview] {
        let found = try InviteFileImporter.interviews(from: url)
        let existing = database.loadExternalInterviews(startingAfter: .distantPast).filter { $0.source == .icsFile }
        database.replaceExternalInterviews(existing + found, source: .icsFile)
        reloadCache()
        return found
    }

    func reloadCache() {
        upcoming = InterviewMerger.merge(database.loadExternalInterviews(startingAfter: now().addingTimeInterval(-2 * 3600))
            .filter(isMine))
        recordings = database.loadExternalRecordings()
        onUpcomingChanged?(upcoming)
    }

    func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.kind == account.kind }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        saveAccounts()
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: Self.accountsKey) }
    }
}
