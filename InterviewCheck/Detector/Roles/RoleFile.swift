import AppKit
import Foundation
import UniformTypeIdentifiers

/// A role saved to a file, to share with other interviewers: the job
/// description, planned questions and cheater prompts.
struct RoleFile: Codable {
    static let formatName = "interviewcheck.role"
    static let maxBytes = 2_000_000

    var format = RoleFile.formatName
    var version = 1
    var exportedAt = Date()
    var role: RoleProfile

    enum Failure: LocalizedError {
        case notARole
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notARole: return "That file is not an \(AppBrand.name) role."
            case .tooLarge: return "That file is too large to be a role."
            }
        }
    }

    static func encode(_ role: RoleProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(RoleFile(role: role))
    }

    /// The role in the file as a new role: its own id and today's dates, so
    /// importing twice never overwrites anything.
    static func decode(_ data: Data) throws -> RoleProfile {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(RoleFile.self, from: data), file.format == formatName else {
            throw Failure.notARole
        }
        var role = file.role
        role.workspaceID = UUID().uuidString
        role.createdAt = Date()
        role.updatedAt = Date()
        return role
    }
}

/// Export and import with the standard save and open panels.
@MainActor
enum RoleTransfer {
    static func export(_ role: RoleProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(role.displayTitle) role.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RoleFile.encode(role).write(to: url, options: .atomic)
        } catch {
            alert("The role could not be saved.", error)
        }
    }

    /// Asks for a role file and adds it; returns the new role.
    static func importWithPanel(into store: RoleStore = .shared) -> RoleProfile? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let role = try RoleFile.decode(Data(contentsOf: url))
            store.save(role)
            return store.role(id: role.id)
        } catch {
            alert("The role could not be imported.", error)
            return nil
        }
    }

    private static func alert(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
