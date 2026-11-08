import Foundation
import AppKit
import CryptoKit

/// Protocol for persisting mode attachments on disk. Extracted so the importer can be tested
/// against an in memory fake.
protocol ModeAttachmentStoring {
    var rootDirectory: URL { get }
    func attachmentsDirectory(for modeID: UUID) throws -> URL
    func thumbnailsDirectory(for modeID: UUID) throws -> URL
    func extractedDirectory(for modeID: UUID) throws -> URL
    func store(fileAt sourceURL: URL, modeID: UUID, attachmentID: UUID, pathExtension: String) throws -> URL
    func removeAttachmentFiles(modeID: UUID, attachmentID: UUID) throws
    func removeDirectory(modeID: UUID) throws
    func exists(storedFilename: String, modeID: UUID) -> Bool
    func sha256(of url: URL) throws -> String
    func size(of url: URL) throws -> Int
}

/// Default implementation rooted at `~/Library/Application Support/memanager/modes/`.
final class FileSystemModeAttachmentStorage: ModeAttachmentStoring {
    static let shared = FileSystemModeAttachmentStorage()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var rootDirectory: URL {
        if TestRuntime.isRunningUnitTests {
            return TestRuntime.temporaryDirectory.appendingPathComponent("modes", isDirectory: true)
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("\(AppBrand.storageFolder)/modes", isDirectory: true)
    }

    func attachmentsDirectory(for modeID: UUID) throws -> URL {
        let url = rootDirectory
            .appendingPathComponent(modeID.uuidString, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func thumbnailsDirectory(for modeID: UUID) throws -> URL {
        let url = rootDirectory
            .appendingPathComponent(modeID.uuidString, isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func extractedDirectory(for modeID: UUID) throws -> URL {
        let url = rootDirectory
            .appendingPathComponent(modeID.uuidString, isDirectory: true)
            .appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func store(fileAt sourceURL: URL, modeID: UUID, attachmentID: UUID, pathExtension: String) throws -> URL {
        let directory = try attachmentsDirectory(for: modeID)
        let filename = "\(attachmentID.uuidString).\(pathExtension)"
        let destination = directory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func removeAttachmentFiles(modeID: UUID, attachmentID: UUID) throws {
        let directories = [
            try attachmentsDirectory(for: modeID),
            try thumbnailsDirectory(for: modeID),
            try extractedDirectory(for: modeID)
        ]
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in contents where item.lastPathComponent.hasPrefix(attachmentID.uuidString) {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    func removeDirectory(modeID: UUID) throws {
        let directory = rootDirectory.appendingPathComponent(modeID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func exists(storedFilename: String, modeID: UUID) -> Bool {
        let url = (try? attachmentsDirectory(for: modeID))?.appendingPathComponent(storedFilename)
        guard let url else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func size(of url: URL) throws -> Int {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }
}
