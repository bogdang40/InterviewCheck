import Foundation
import InterviewCheckConnectors

/// The refresh token one OAuth session holds, to tell whether the saved
/// tokens are still that session's. After the user signs in again (maybe to
/// another account) a refresh still in flight from the old session must not
/// overwrite the new tokens.
final class RefreshTokenLineage: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?

    init(_ tokens: OAuthTokens) {
        current = tokens.refreshToken
    }

    /// Saves `updated` only while the store still holds this session's
    /// tokens; returns whether it saved.
    @discardableResult
    func save(_ updated: OAuthTokens, kind: ConnectorKind, in store: CredentialStore) -> Bool {
        lock.withLock {
            // Not after a disconnect: the account is gone for good.
            guard var saved = store.load(kind.rawValue), saved.tokens?.refreshToken == current else { return false }
            saved.tokens = updated
            guard (try? store.save(saved, for: kind.rawValue)) != nil else { return false }
            current = updated.refreshToken
            return true
        }
    }
}
