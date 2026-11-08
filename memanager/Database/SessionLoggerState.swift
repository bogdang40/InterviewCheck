import Foundation

/// Lock guarded mutable identity of the logging session.
///
/// SessionLogger is a shared singleton touched from the main thread, detached
/// summary tasks, and audio callbacks; these three fields were plain vars
/// with no synchronization.
final class SessionLoggerState {
    private let lock = NSLock()
    private var _sessionId: String?
    private var _provider: String?
    private var _model: String?
    private var _resumedRecord: SessionRecord?

    var resumedRecord: SessionRecord? {
        get { lock.withLock { _resumedRecord } }
        set { lock.withLock { _resumedRecord = newValue } }
    }

    var sessionId: String? {
        get { lock.withLock { _sessionId } }
        set { lock.withLock { _sessionId = newValue } }
    }

    var provider: String? {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }

    var model: String? {
        get { lock.withLock { _model } }
        set { lock.withLock { _model = newValue } }
    }

    func update(sessionId: String?, provider: String?, model: String?) {
        lock.withLock {
            _sessionId = sessionId
            _provider = provider
            _model = model
        }
    }
}
