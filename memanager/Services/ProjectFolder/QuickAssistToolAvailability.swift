import Foundation

enum QuickAssistToolAvailability: Equatable {
    case available(root: ProjectToolRootDescriptor)
    case noProjectFolder
    case rootMismatch(boundRoot: ProjectToolRootDescriptor, liveRootPath: String?)
    case unsupportedProvider(providerDisplayName: String, root: ProjectToolRootDescriptor?)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var rootDescriptor: ProjectToolRootDescriptor? {
        switch self {
        case .available(let root):
            return root
        case .rootMismatch(let boundRoot, _):
            return boundRoot
        case .unsupportedProvider(_, let root):
            return root
        case .noProjectFolder:
            return nil
        }
    }

    var helpText: String {
        switch self {
        case .available(let root):
            return "Bound root: \(root.rootName) at \(root.displayPath). Tools gather project information first, then the assistant answers using those findings."
        case .noProjectFolder:
            return "Enable a project folder on this Mode in Settings to turn tools on."
        case .rootMismatch(let boundRoot, let liveRootPath):
            if let liveRootPath, !liveRootPath.isEmpty {
                return "This thread is still bound to \(boundRoot.displayPath), but the active Mode now points to \(liveRootPath). Use a matching Mode or start a new thread to enable tools."
            }
            return "This thread is still bound to \(boundRoot.displayPath), but the active Mode no longer has a matching project folder. Use a matching Mode or start a new thread to enable tools."
        case .unsupportedProvider(let providerDisplayName, let root):
            if let root {
                return "\(providerDisplayName) does not support the project tool loop for this thread. Bound root: \(root.displayPath). Switch to Claude or OpenAI."
            }
            return "\(providerDisplayName) does not support the project tool loop. Switch to Claude or OpenAI."
        }
    }

    var disabledLabel: String {
        switch self {
        case .available:
            return "Tools"
        case .noProjectFolder:
            return "No project folder"
        case .rootMismatch:
            return "Root mismatch"
        case .unsupportedProvider:
            return "Provider unsupported"
        }
    }
}

protocol QuickAssistToolAvailabilityResolving {
    func resolve(for session: Session, providerType: AIProviderType) -> QuickAssistToolAvailability
}

final class QuickAssistToolAvailabilityResolver: QuickAssistToolAvailabilityResolving {
    static let shared = QuickAssistToolAvailabilityResolver()

    private let snapshotWriter: SessionModeSnapshotWriter
    private let activeModeProvider: () -> Mode?
    private let modeLookup: (UUID) -> Mode?

    init(
        snapshotWriter: SessionModeSnapshotWriter = .shared,
        activeModeProvider: @escaping () -> Mode? = { ModeStoreBridge.activeMode() },
        modeLookup: @escaping (UUID) -> Mode? = { ModeStoreBridge.mode(id: $0) }
    ) {
        self.snapshotWriter = snapshotWriter
        self.activeModeProvider = activeModeProvider
        self.modeLookup = modeLookup
    }

    func resolve(for session: Session, providerType: AIProviderType) -> QuickAssistToolAvailability {
        if let snapshot = resolvedSnapshot(for: session) {
            return resolveSnapshotBoundAvailability(snapshot: snapshot, providerType: providerType)
        }
        return resolveLiveAvailability(providerType: providerType)
    }

    private func resolveSnapshotBoundAvailability(
        snapshot: SessionModeSnapshot,
        providerType: AIProviderType
    ) -> QuickAssistToolAvailability {
        guard snapshot.projectFolderEnabledAtCapture,
              let boundPath = normalizedPath(snapshot.projectFolderDisplayPath) else {
            return .noProjectFolder
        }

        let boundRoot = ProjectToolRootDescriptor(
            rootName: URL(fileURLWithPath: boundPath).lastPathComponent,
            displayPath: boundPath
        )

        guard let sourceModeID = snapshot.sourceModeID,
              let liveMode = modeLookup(sourceModeID),
              let projectFolder = liveMode.projectFolder,
              projectFolder.isEnabled,
              projectFolder.bookmarkData != nil else {
            return .rootMismatch(boundRoot: boundRoot, liveRootPath: nil)
        }

        let liveRoot = ProjectToolRootDescriptor(config: projectFolder)
        guard normalizedPath(liveRoot.displayPath) == boundPath else {
            return .rootMismatch(boundRoot: boundRoot, liveRootPath: liveRoot.displayPath)
        }
        guard supportsProvider(providerType) else {
            return .unsupportedProvider(providerDisplayName: providerType.displayName, root: boundRoot)
        }
        return .available(root: boundRoot)
    }

    private func resolveLiveAvailability(providerType: AIProviderType) -> QuickAssistToolAvailability {
        guard let liveMode = activeModeProvider(),
              let projectFolder = liveMode.projectFolder,
              projectFolder.isEnabled,
              projectFolder.bookmarkData != nil else {
            return .noProjectFolder
        }
        let root = ProjectToolRootDescriptor(config: projectFolder)
        guard supportsProvider(providerType) else {
            return .unsupportedProvider(providerDisplayName: providerType.displayName, root: root)
        }
        return .available(root: root)
    }

    private func resolvedSnapshot(for session: Session) -> SessionModeSnapshot? {
        if let snapshotID = session.activeModeSnapshotID,
           let snapshot = snapshotWriter.loadSnapshot(snapshotID: snapshotID) {
            return snapshot
        }
        return snapshotWriter.loadSnapshot(sessionID: session.id)
    }

    private func supportsProvider(_ providerType: AIProviderType) -> Bool {
        switch providerType {
        case .claude, .openai:
            return true
        case .azureOpenAI:
            return false
        }
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return (trimmed as NSString).standardizingPath
    }
}
