import XCTest
@testable import memanager

final class SessionModeContextResolverTests: XCTestCase {
    private var database: SessionDatabase!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("mode.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testSessionModeContextResolverUsesFrozenSnapshotInsteadOfLiveMode() throws {
        let sessionID = UUID()
        let snapshotID = UUID()
        let sourceModeID = UUID()
        let frozenAttachment = ModeAttachment(
            modeID: sourceModeID,
            kind: .text,
            originalFilename: "notes.txt",
            storedFilename: "notes.txt",
            byteSize: 32,
            sha256: "sha",
            extractedText: "Frozen attachment evidence"
        )
        let attachmentsJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode([frozenAttachment]), encoding: .utf8)
        )
        database.saveSessionModeSnapshot(
            SessionModeSnapshotRecord(
                snapshotID: snapshotID.uuidString,
                sessionID: sessionID.uuidString,
                sourceModeID: sourceModeID.uuidString,
                capturedAt: Date(),
                title: "Frozen Mode",
                promptText: "Frozen prompt",
                attachmentsJSON: attachmentsJSON,
                projectFolderDisplayPath: "/tmp/project",
                projectFolderEnabledAtCapture: true,
                createdAt: Date()
            )
        )

        let liveMode = Mode(
            id: sourceModeID,
            title: "Live Mode",
            prompt: "Live prompt",
            attachments: [
                ModeAttachment(
                    modeID: sourceModeID,
                    kind: .text,
                    originalFilename: "live.txt",
                    storedFilename: "live.txt",
                    byteSize: 16,
                    sha256: "live",
                    extractedText: "Live attachment evidence"
                )
            ]
        )
        let resolver = SessionModeContextResolver(
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage.shared,
                snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
            ),
            snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared,
            activeModeProvider: { liveMode },
            modeLookup: { _ in liveMode }
        )
        var session = Session()
        session.id = sessionID
        session.activeModeSnapshotID = snapshotID

        let composition = resolver.composeContext(for: session, fallbackRealtimePrompt: "Base prompt")
        let prompt = try XCTUnwrap(composition?.realtimePromptText)

        XCTAssertTrue(prompt.contains("Frozen Mode"))
        XCTAssertTrue(prompt.contains("Frozen prompt"))
        XCTAssertTrue(prompt.contains("Frozen attachment evidence"))
        XCTAssertTrue(prompt.contains("Base prompt"))
        XCTAssertFalse(prompt.contains("Live prompt"))
        XCTAssertFalse(prompt.contains("Live attachment evidence"))
    }

    func testSessionModeContextResolverDisablesToolModeWhenFolderPathChanged() {
        let sessionID = UUID()
        let snapshotID = UUID()
        let sourceModeID = UUID()
        database.saveSessionModeSnapshot(
            SessionModeSnapshotRecord(
                snapshotID: snapshotID.uuidString,
                sessionID: sessionID.uuidString,
                sourceModeID: sourceModeID.uuidString,
                capturedAt: Date(),
                title: "Frozen Mode",
                promptText: "Frozen prompt",
                attachmentsJSON: "[]",
                projectFolderDisplayPath: "/tmp/original-project",
                projectFolderEnabledAtCapture: true,
                createdAt: Date()
            )
        )

        let liveMode = Mode(
            id: sourceModeID,
            title: "Live Mode",
            prompt: "Live prompt",
            attachments: [],
            projectFolder: ProjectFolderConfig(
                isEnabled: true,
                bookmarkData: Data([1, 2, 3]),
                displayPath: "/tmp/different-project",
                rootName: "different"
            )
        )
        let resolver = SessionModeContextResolver(
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage.shared,
                snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
            ),
            snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared,
            activeModeProvider: { liveMode },
            modeLookup: { _ in liveMode }
        )
        var session = Session()
        session.id = sessionID
        session.activeModeSnapshotID = snapshotID

        XCTAssertNil(resolver.resolveToolMode(for: session))
    }

    func testSessionModeContextResolverRestoresToolModeWhenFolderPathMatches() {
        let sessionID = UUID()
        let snapshotID = UUID()
        let sourceModeID = UUID()
        database.saveSessionModeSnapshot(
            SessionModeSnapshotRecord(
                snapshotID: snapshotID.uuidString,
                sessionID: sessionID.uuidString,
                sourceModeID: sourceModeID.uuidString,
                capturedAt: Date(),
                title: "Frozen Mode",
                promptText: "Frozen prompt",
                attachmentsJSON: "[]",
                projectFolderDisplayPath: "/tmp/original-project",
                projectFolderEnabledAtCapture: true,
                createdAt: Date()
            )
        )

        let liveMode = Mode(
            id: sourceModeID,
            title: "Live Mode",
            prompt: "Live prompt",
            attachments: [],
            projectFolder: ProjectFolderConfig(
                isEnabled: true,
                bookmarkData: Data([1, 2, 3]),
                displayPath: "/tmp/original-project",
                rootName: "original"
            )
        )
        let resolver = SessionModeContextResolver(
            snapshotWriter: SessionModeSnapshotWriter(
                database: database,
                modeProvider: { nil },
                attachmentStorage: FileSystemModeAttachmentStorage.shared,
                snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared
            ),
            snapshotAssetStorage: SessionModeSnapshotAssetStorage.shared,
            activeModeProvider: { liveMode },
            modeLookup: { _ in liveMode }
        )
        var session = Session()
        session.id = sessionID
        session.activeModeSnapshotID = snapshotID

        XCTAssertEqual(resolver.resolveToolMode(for: session)?.id, sourceModeID)
    }
}
