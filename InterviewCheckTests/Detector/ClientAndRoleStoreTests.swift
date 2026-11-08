import XCTest
@testable import InterviewCheck

final class ClientAndRoleStoreTests: XCTestCase {
    func testAzureURLFromAPlainEndpoint() {
        let url = AzureTextClient.requestURL(endpoint: "https://acme.openai.azure.com/", deployment: "gpt-4o",
                                             apiVersion: "2024-02-01")
        XCTAssertEqual(url?.absoluteString,
                       "https://acme.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01")
    }

    func testAzureURLDropsAPastedPathAndQuery() {
        let url = AzureTextClient.requestURL(
            endpoint: "https://acme.openai.azure.com/openai/deployments/old/chat/completions?api-version=x",
            deployment: "mini", apiVersion: "2024-06-01")
        XCTAssertEqual(url?.absoluteString,
                       "https://acme.openai.azure.com/openai/deployments/mini/chat/completions?api-version=2024-06-01")
    }

    func testChatCompletionsDeltaParsing() {
        XCTAssertEqual(ChatCompletionsDelta.parse(Data(#"{"choices":[{"delta":{"content":"Hi"}}]}"#.utf8)), "Hi")
        XCTAssertNil(ChatCompletionsDelta.parse(Data(#"{"choices":[{"delta":{}}]}"#.utf8)))
        XCTAssertNil(ChatCompletionsDelta.parse(Data("not json".utf8)))
    }

    func testClaudeDeltaParsing() {
        let delta = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(ClaudeTextClient.parseDelta(Data(delta.utf8)), "Hello")
        XCTAssertNil(ClaudeTextClient.parseDelta(Data(#"{"type":"message_start"}"#.utf8)))
    }

    func testModelNames() {
        XCTAssertEqual(DetectorModelNames.short("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(DetectorModelNames.providerShort(.openai, model: "gpt-4o-mini"), "GPT 4o Mini")
        XCTAssertEqual(DetectorModelNames.providerShort(.azureOpenAI, model: "prod-gpt"), "Azure prod-gpt")
    }

    @MainActor
    func testRoleStoreCreateSaveSelectDelete() {
        let path = NSTemporaryDirectory() + "roles-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let defaults = UserDefaults(suiteName: "roles.\(UUID().uuidString)")!
        let store = RoleStore(database: SessionDatabase(databasePath: path), defaults: defaults)
        XCTAssertTrue(store.roles.isEmpty)

        var role = store.create(name: "Backend Engineer", company: "Acme")
        XCTAssertEqual(store.selectedRoleID, role.id, "the first role is selected for the next interview")
        role.jobDescription = "Go and Postgres"
        store.save(role)

        let reloaded = RoleStore(database: SessionDatabase(databasePath: path), defaults: defaults)
        XCTAssertEqual(reloaded.roles.first?.jobDescription, "Go and Postgres")
        XCTAssertEqual(reloaded.selectedRole?.displayTitle, "Backend Engineer at Acme")

        reloaded.delete(role.id)
        XCTAssertTrue(reloaded.roles.isEmpty)
        XCTAssertNil(reloaded.selectedRoleID)
    }

    func testOlderRoleJSONDecodesWithDefaults() throws {
        let json = #"{"workspaceID":"w1","jobDescription":"JD"}"#
        let role = try JSONDecoder().decode(RoleProfile.self, from: Data(json.utf8))
        XCTAssertEqual(role.displayTitle, "Untitled role")
        XCTAssertEqual(role.cheaterPrompts.count, 3)
    }
}
