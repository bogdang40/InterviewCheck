import Foundation
import Combine

/// Observable, durable store for the user's Modes. Wraps `UserDefaults` persistence and
/// file system attachment storage. Single source of truth for Quick Assist mode injection.
@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    @Published private(set) var modes: [Mode]
    @Published private(set) var activeModeID: UUID?

    private let defaults: UserDefaults
    private let storage: ModeAttachmentStoring
    private let modesKey = "memanager.modes"
    private let activeModeIDKey = "memanager.activeModeID"

    init(
        defaults: UserDefaults = AppDefaults.standard,
        storage: ModeAttachmentStoring = FileSystemModeAttachmentStorage.shared
    ) {
        self.defaults = defaults
        self.storage = storage
        let loaded = ModeStore.loadModes(from: defaults, key: modesKey)
        self.modes = loaded
        self.activeModeID = ModeStore.loadActiveID(from: defaults, key: activeModeIDKey, modes: loaded)
    }

    // MARK: - Accessors

    var activeMode: Mode? {
        guard let activeModeID else { return nil }
        return modes.first(where: { $0.id == activeModeID })
    }

    func mode(with id: UUID) -> Mode? {
        modes.first(where: { $0.id == id })
    }

    // MARK: - CRUD

    func addMode(title: String = "New Mode", prompt: String = "") -> Mode {
        let mode = Mode(title: title, prompt: prompt)
        modes.append(mode)
        persistModes()
        return mode
    }

    func updateMode(_ mode: Mode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var updated = mode
        updated.updatedAt = Date()
        modes[index] = updated
        persistModes()
    }

    func replaceAll(_ incoming: [Mode], activeID: UUID?) {
        modes = incoming
        if let activeID, incoming.contains(where: { $0.id == activeID }) {
            activeModeID = activeID
        } else {
            activeModeID = incoming.first?.id
        }
        persistModes()
        persistActiveID()
    }

    func setActive(_ id: UUID?) {
        if let id, modes.contains(where: { $0.id == id }) {
            activeModeID = id
        } else {
            activeModeID = nil
        }
        persistActiveID()
    }

    func deleteMode(id: UUID) {
        modes.removeAll(where: { $0.id == id })
        if activeModeID == id {
            activeModeID = modes.first?.id
            persistActiveID()
        }
        try? storage.removeDirectory(modeID: id)
        persistModes()
    }

    // MARK: - Attachment mutations

    func addAttachment(_ attachment: ModeAttachment, toMode modeID: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[index].attachments.append(attachment)
        modes[index].updatedAt = Date()
        persistModes()
    }

    func removeAttachment(attachmentID: UUID, modeID: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[index].attachments.removeAll(where: { $0.id == attachmentID })
        modes[index].updatedAt = Date()
        try? storage.removeAttachmentFiles(modeID: modeID, attachmentID: attachmentID)
        persistModes()
    }

    // MARK: - Project folder

    func setProjectFolder(_ config: ProjectFolderConfig?, modeID: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[index].projectFolder = config
        modes[index].updatedAt = Date()
        persistModes()
    }

    // MARK: - Persistence

    private func persistModes() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        defaults.set(data, forKey: modesKey)
    }

    private func persistActiveID() {
        if let activeModeID {
            defaults.set(activeModeID.uuidString, forKey: activeModeIDKey)
        } else {
            defaults.removeObject(forKey: activeModeIDKey)
        }
    }

    private static func loadModes(from defaults: UserDefaults, key: String) -> [Mode] {
        guard
            let data = defaults.data(forKey: key),
            let loaded = try? JSONDecoder().decode([Mode].self, from: data)
        else {
            return []
        }
        return loaded
    }

    private static func loadActiveID(from defaults: UserDefaults, key: String, modes: [Mode]) -> UUID? {
        guard
            let raw = defaults.string(forKey: key),
            let uuid = UUID(uuidString: raw),
            modes.contains(where: { $0.id == uuid })
        else {
            return modes.first?.id
        }
        return uuid
    }
}
