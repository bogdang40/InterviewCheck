import XCTest
@testable import memanager

final class APIErrorBodyParserTests: XCTestCase {
    func testExtractsCodeAndMessage() {
        let body = Data(
            #"{"error":{"message":"Unsupported parameter","code":"unsupported_parameter","param":"reasoning"}}"#.utf8
        )

        let details = APIErrorBodyParser.parse(body)

        XCTAssertEqual(details.apiCode, "unsupported_parameter")
        XCTAssertEqual(details.message, "Unsupported parameter")
    }

    func testFallsBackToParamThenType() {
        let paramOnly = Data(#"{"error":{"message":"Bad","param":"input_image"}}"#.utf8)
        XCTAssertEqual(APIErrorBodyParser.parse(paramOnly).apiCode, "input_image")

        let typeOnly = Data(#"{"error":{"message":"Bad","type":"invalid_request_error"}}"#.utf8)
        XCTAssertEqual(APIErrorBodyParser.parse(typeOnly).apiCode, "invalid_request_error")
    }

    func testNonJSONBodyBecomesRawMessage() {
        let details = APIErrorBodyParser.parse(Data("upstream exploded".utf8))

        XCTAssertNil(details.apiCode)
        XCTAssertEqual(details.message, "upstream exploded")
    }

    func testEmptyBodyBecomesUnknownError() {
        let details = APIErrorBodyParser.parse(Data())

        XCTAssertNil(details.apiCode)
        XCTAssertEqual(details.message, "Unknown error")
    }
}

final class AIProviderFactoryTests: XCTestCase {
    func testAzureWithoutConfigThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(
            try AIProviderFactory.create(type: .azureOpenAI, apiKey: "key")
        ) { error in
            guard case ProviderConfigurationError.missingAzureConfig = error else {
                return XCTFail("Expected missingAzureConfig, got \(error)")
            }
        }
    }

    func testAzureWithConfigCreatesProvider() throws {
        let provider = try AIProviderFactory.create(
            type: .azureOpenAI,
            apiKey: "key",
            azureConfig: AzureOpenAIConfig(
                endpoint: "https://example.openai.azure.com",
                deploymentName: "gpt-4o",
                apiVersion: "2024-02-01"
            )
        )

        XCTAssertTrue(provider is AzureOpenAIProvider)
    }

    func testNonAzureProvidersCreateWithoutConfig() throws {
        XCTAssertTrue(try AIProviderFactory.create(type: .openai, apiKey: "key") is OpenAIProvider)
        XCTAssertTrue(try AIProviderFactory.create(type: .claude, apiKey: "key") is ClaudeProvider)
    }
}
