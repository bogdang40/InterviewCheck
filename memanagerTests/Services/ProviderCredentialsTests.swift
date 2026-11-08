import XCTest
@testable import memanager

final class ProviderCredentialsTests: XCTestCase {
    func testEnvironmentPrecedesFileAndKeychainWithoutReadingEither() throws {
        let key = try ProviderCredentials.resolve(
            provider: .openai, key: "synthetic",
            environment: ["MEMANAGER_OPENAI_API_KEY": " env value "],
            fileValue: { _ in XCTFail("Environment should win"); return nil },
            keychainValue: { _ in XCTFail("Environment should win"); return nil }
        )
        XCTAssertEqual(key, "env value")
    }

    func testFilePrecedesKeychainWhenEnvironmentIsBlank() throws {
        let key = try ProviderCredentials.resolve(
            provider: .claude, key: "synthetic",
            environment: ["MEMANAGER_CLAUDE_API_KEY": "  "],
            fileValue: { name in
                XCTAssertEqual(name, "MEMANAGER_CLAUDE_API_KEY")
                return " file value "
            },
            keychainValue: { _ in XCTFail("File should win"); return nil }
        )
        XCTAssertEqual(key, "file value")
    }

    func testUnavailableKeychainPropagatesWhenNoOverrideExists() {
        XCTAssertThrowsError(try ProviderCredentials.resolve(
            provider: .azureOpenAI, key: "synthetic", environment: [:],
            fileValue: { _ in nil },
            keychainValue: { _ in throw CredentialStorageError.invalidEncoding }
        ))
    }

    func testHydrationPreservesEditedAndClearedDrafts() {
        var draft = AIProviderSettingsDraft()
        draft.editAPIKey("new value", for: .openai)
        draft.editAPIKey("", for: .claude)
        draft.hydrateAPIKey("old value", for: .openai, status: .configured)
        draft.hydrateAPIKey("old value", for: .claude, status: .configured)
        draft.hydrateAPIKey("azure value", for: .azureOpenAI, status: .configured)
        XCTAssertEqual(draft.openAIAPIKey, "new value")
        XCTAssertEqual(draft.claudeAPIKey, "")
        XCTAssertEqual(draft.azureAPIKey, "azure value")
    }

    func testLoadingAndUnavailableDoNotHydrateDrafts() {
        var draft = AIProviderSettingsDraft()
        draft.hydrateAPIKey("cached", for: .claude, status: .loading)
        draft.hydrateAPIKey("cached", for: .openai, status: .unavailable("denied"))
        XCTAssertEqual(draft.claudeAPIKey, "")
        XCTAssertEqual(draft.openAIAPIKey, "")
    }
}
