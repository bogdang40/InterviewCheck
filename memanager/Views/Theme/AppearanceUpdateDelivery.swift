import Foundation

/// Apply only the latest appearance after its settings write finishes. AppKit
/// geometry changes must not reenter SwiftUI from an @Published willSet callback.
final class AppearanceUpdateDelivery {
    private let lock = NSLock()
    private var pendingUpdate: (() -> Void)?
    private var isScheduled = false

    func submit(_ update: @escaping () -> Void) {
        lock.lock()
        pendingUpdate = update
        let needsScheduling = !isScheduled
        isScheduled = true
        lock.unlock()
        guard needsScheduling else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingUpdate() }
    }

    private func applyPendingUpdate() {
        lock.lock()
        let update = pendingUpdate
        pendingUpdate = nil
        isScheduled = false
        lock.unlock()
        update?()
    }
}
