import XCTest
@testable import memanager

final class SettingsComponentResolverTests: XCTestCase {
    private let curated = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    func testChangingConfigurationRejectsAnInFlightConnectionResult() {
        var state = APITestState()
        let oldRequest = state.begin()
        state.invalidate()
        let newRequest = state.begin()
        let result = APITestResult(success: true, message: "ok", modelInfo: "fixture", responseTime: 0.2)
        state.finish(result, requestID: oldRequest)
        XCTAssertNil(state.result, "a successful test of the previous key must not verify the new key")
        XCTAssertTrue(state.isLoading)
        state.finish(result, requestID: newRequest)
        XCTAssertEqual(state.result?.modelInfo, "fixture")
        XCTAssertFalse(state.isLoading)
        state.invalidate()
        XCTAssertNil(state.result)
    }

    func testShortcutSearchRetainsEveryRegistryActionAndCanFilterScope() {
        let all = HotkeyInventorySection.allCases.flatMap { HotkeySearch.entries(query: "", section: $0, selection: nil) }
        XCTAssertEqual(Set(all.map(\.id)), Set(HotkeyRegistry.entries.map(\.id)))
        let local = HotkeyInventorySection.allCases.flatMap { HotkeySearch.entries(query: "keyboard focus", section: $0, selection: nil) }
        XCTAssertFalse(local.isEmpty)
        XCTAssertTrue(local.allSatisfy { $0.scope == .overlayLocal })
        XCTAssertTrue(HotkeySearch.entries(query: "no matching fixture action", section: .session, selection: nil).isEmpty)
    }

    @MainActor
    func testModeDraftSurvivesSelectionAndMergesWithCurrentAttachments() throws {
        let suite = "ModeDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModeStore(defaults: defaults)
        let first = store.addMode(title: "First", prompt: "Saved prompt")
        let second = store.addMode(title: "Second")
        let editing = ModeEditingState()
        editing.update(first) { $0.prompt = "Draft prompt" }
        editing.selectedModeID = second.id
        editing.retain(store.modes)
        XCTAssertEqual(editing.draft(for: first).prompt, "Draft prompt")
        XCTAssertEqual(store.mode(with: first.id)?.prompt, "Saved prompt")
        let attachment = ModeAttachment(modeID: first.id, kind: .pdf, originalFilename: "fixture.pdf", storedFilename: "fixture.pdf", byteSize: 1, sha256: "fixture", pageCount: 1)
        store.addAttachment(attachment, toMode: first.id)
        editing.save(modeID: first.id, store: store)
        let saved = try XCTUnwrap(store.mode(with: first.id))
        XCTAssertEqual(saved.prompt, "Draft prompt")
        XCTAssertEqual(saved.attachments.map(\.id), [attachment.id])
        XCTAssertFalse(editing.draft(for: saved).isDirty)
        editing.update(saved) { $0.title = "Discard me" }
        editing.discard(modeID: saved.id)
        XCTAssertEqual(editing.draft(for: saved).title, "First")
    }

    // MARK: ModelChoiceResolver

    func testCuratedModelResolvesToCuratedChoice() {
        XCTAssertEqual(ModelChoiceResolver.choice(for: "claude-sonnet-5", curated: curated), .curated("claude-sonnet-5"))
        XCTAssertEqual(ModelChoiceResolver.choice(for: "  claude-sonnet-5 ", curated: curated), .curated("claude-sonnet-5"))
    }

    func testUnknownModelResolvesToCustomChoice() {
        let choice = ModelChoiceResolver.choice(for: "claude-experimental", curated: curated)
        XCTAssertEqual(choice, .custom("claude-experimental"))
        XCTAssertTrue(choice.isCustom)
        XCTAssertEqual(ModelChoiceResolver.menuTitle(for: choice), ModelChoiceResolver.customTitle)
        XCTAssertEqual(ModelChoiceResolver.menuTitle(for: .curated("x")), "x")
    }

    func testSelectingCustomKeepsTypedValueButClearsCuratedOne() {
        XCTAssertEqual(ModelChoiceResolver.model(afterSelecting: nil, current: "claude-sonnet-5", curated: curated), "")
        XCTAssertEqual(ModelChoiceResolver.model(afterSelecting: nil, current: "my-model", curated: curated), "my-model")
        XCTAssertEqual(ModelChoiceResolver.model(afterSelecting: "claude-opus-5", current: "my-model", curated: curated), "claude-opus-5")
    }

    // MARK: SettingsKeyStatus

    func testKeyStatusInferredFromText() {
        XCTAssertEqual(SettingsKeyStatus.inferred(from: "   "), .missing)
        XCTAssertEqual(SettingsKeyStatus.inferred(from: "sk-1"), .configured)
        XCTAssertEqual(SettingsKeyStatus.failed("boom").help, "boom")
        XCTAssertNil(SettingsKeyStatus.configured.help)
        XCTAssertEqual(SettingsKeyStatus.missing.tone, .warning)
    }

    // MARK: PermissionRowState

    func testPermissionStatusMapsToDotAndTone() {
        XCTAssertEqual(PermissionRowState.dotState(for: .granted), .ready)
        XCTAssertEqual(PermissionRowState.dotState(for: .denied), .error)
        XCTAssertEqual(PermissionRowState.dotState(for: .restricted), .error)
        XCTAssertEqual(PermissionRowState.dotState(for: .notDetermined), .idle)
        XCTAssertEqual(PermissionRowState.badgeTone(for: .granted), .success)
        XCTAssertEqual(PermissionRowState.badgeTone(for: .notDetermined), .warning)
    }

    func testPermissionSummaryCountsMissing() {
        let none = PermissionRowState.summary(missingCount: 0)
        XCTAssertEqual(none.tone, .success)
        let one = PermissionRowState.summary(missingCount: 1)
        XCTAssertEqual(one.tone, .warning)
        XCTAssertTrue(one.message.hasPrefix("1 permission needs"))
        XCTAssertTrue(PermissionRowState.summary(missingCount: 3).message.hasPrefix("3 permissions need"))
    }

    // MARK: Mode presentation

    func testModeListRowSummaryPrefersAttachmentsAndFolderOverPrompt() {
        let empty = Mode(title: "A", prompt: "   ")
        XCTAssertEqual(ModeListRowSummary.subtitle(for: empty), "Empty prompt")
        let prompted = Mode(title: "A", prompt: "Be brief")
        XCTAssertEqual(ModeListRowSummary.subtitle(for: prompted), "Be brief")
        let attachment = ModeAttachment(modeID: prompted.id, kind: .pdf, originalFilename: "cv.pdf", storedFilename: "cv.pdf", byteSize: 2048, sha256: "x", pageCount: 2)
        let rich = Mode(title: "A", prompt: "Be brief", attachments: [attachment], projectFolder: ProjectFolderConfig(isEnabled: true))
        XCTAssertEqual(ModeListRowSummary.subtitle(for: rich), "1 attachment, project folder")
        XCTAssertEqual(ModeAttachmentPresentation.detail(for: attachment), "2 KB, 2 pages")
        XCTAssertEqual(ModeAttachmentPresentation.systemImage(for: .markdown), "doc.text")
    }

    func testProjectFolderPresentation() {
        XCTAssertEqual(ProjectFolderPresentation.folderTitle(for: ProjectFolderConfig()), "No folder selected")
        let picked = ProjectFolderConfig(displayPath: "/Users/me/app", rootName: "app")
        XCTAssertEqual(ProjectFolderPresentation.folderTitle(for: picked), "app")
        XCTAssertEqual(ProjectFolderPresentation.folderHelper(for: picked), "/Users/me/app")
    }
}
