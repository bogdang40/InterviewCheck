import AVFoundation

/// Owns the AVAudioEngineConfigurationChange observation for one engine at a
/// time. Block based notification observers can only be removed through the
/// token returned at registration; this type keeps that token so re-attaching
/// (for a fresh engine) or detaching never strands a live observer.
final class EngineConfigurationObserver {
    private var token: NSObjectProtocol?
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Replaces any previous observation with one scoped to `engine`.
    func attach(to engine: AVAudioEngine, handler: @escaping () -> Void) {
        detach()
        token = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            handler()
        }
    }

    func detach() {
        if let token {
            center.removeObserver(token)
        }
        token = nil
    }

    deinit {
        detach()
    }
}
