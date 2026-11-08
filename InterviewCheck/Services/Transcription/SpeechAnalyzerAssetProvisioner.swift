import Foundation
import Speech

/// Owns the lifecycle of the on device SpeechAnalyzer model assets.
///
/// The transcription engine resolver only flips to the analyzer once assets are
/// actually installed, so a fresh machine keeps working on its previous engine
/// while the model downloads in the background. Kick `provisionIfNeeded()` at
/// app launch and before capture starts; both are cheap no-ops once ready.
final class SpeechAnalyzerAssetProvisioner: ObservableObject {
    static let shared = SpeechAnalyzerAssetProvisioner()

    enum ProvisionState: Equatable {
        case idle
        case unsupported
        case checking
        case downloading
        case ready
        case failed(String)
    }

    /// Main thread only, for settings and diagnostics UI.
    @Published private(set) var state: ProvisionState = .idle

    private let lock = NSLock()
    private var readyFlag = false
    private var resolvedLocale: Locale?
    private var provisionTask: Task<Void, Never>?

    private init() {}

    /// Thread safe snapshot for the capture start path.
    var isReadySnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readyFlag
    }

    /// The OS normalized locale the analyzer should be created with.
    var resolvedLocaleSnapshot: Locale? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedLocale
    }

    func provisionIfNeeded() {
        lock.lock()
        let alreadyReady = readyFlag
        let alreadyRunning = provisionTask != nil
        lock.unlock()
        guard !alreadyReady, !alreadyRunning else { return }

        let task = Task { [weak self] in
            await self?.run()
            self?.clearTask()
        }
        lock.lock()
        provisionTask = task
        lock.unlock()
    }

    private func clearTask() {
        lock.lock()
        provisionTask = nil
        lock.unlock()
    }

    private func run() async {
        guard #available(macOS 26.0, *) else {
            setState(.unsupported)
            return
        }
        setState(.checking)

        guard SpeechTranscriber.isAvailable else {
            setState(.unsupported)
            return
        }

        let requested = Locale(identifier: "en_US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            setState(.unsupported)
            return
        }
        storeResolvedLocale(locale)

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])

        switch status {
        case .installed:
            markReady()
            return
        case .unsupported:
            setState(.unsupported)
            return
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                setState(.downloading)
                try await request.downloadAndInstall()
            }
            let finalStatus = await AssetInventory.status(forModules: [transcriber])
            if finalStatus == .installed {
                markReady()
            } else {
                setState(.failed("Model assets unavailable after install (status: \(finalStatus))"))
            }
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func storeResolvedLocale(_ locale: Locale) {
        lock.lock()
        resolvedLocale = locale
        lock.unlock()
    }

    private func markReady() {
        lock.lock()
        readyFlag = true
        lock.unlock()
        setState(.ready)
    }

    private func setState(_ newState: ProvisionState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}
