import XCTest
@testable import memanager

final class HotkeyRegistryTests: XCTestCase {
    func testRegistryHasNoDuplicateBoundEntries() {
        XCTAssertTrue(HotkeyRegistry.duplicateBindings().isEmpty)
    }

    func testSettingsInventoryCoversUndocumentedRuntimeBindings() {
        let shortcuts = Set(HotkeyRegistry.settingsEntries.map(\.shortcut))

        XCTAssertTrue(shortcuts.contains("Cmd+="))
        XCTAssertTrue(shortcuts.contains("Cmd+-"))
        XCTAssertTrue(shortcuts.contains("Cmd+."))
        XCTAssertTrue(shortcuts.contains("Cmd+Shift+,"))
        XCTAssertTrue(shortcuts.contains("Cmd+T"))
        XCTAssertTrue(shortcuts.contains("Cmd+Down"))
        XCTAssertTrue(shortcuts.contains("Cmd+Up"))
        XCTAssertTrue(shortcuts.contains("Cmd+Shift+Y"))
        XCTAssertTrue(shortcuts.contains("Cmd+Option+/"))
        XCTAssertTrue(shortcuts.contains("Cmd+0"))
    }

    func testPersistedRegistryEntriesMatchDefaultBindings() {
        let persistedKeys = Set(HotkeyRegistry.persistedEntries.compactMap(\.persistedBindingKey))
        let defaultBindingKeys = Set(HotkeyRegistry.defaultBindings.keys)

        XCTAssertEqual(persistedKeys, defaultBindingKeys)
    }
}
