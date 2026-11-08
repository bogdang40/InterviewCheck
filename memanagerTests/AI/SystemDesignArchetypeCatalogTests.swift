import XCTest
@testable import memanager

final class SystemDesignArchetypeCatalogTests: XCTestCase {
    func testDetectsClassicArchetypes() {
        let cases: [(transcript: String, expectedID: String)] = [
            ("Interviewer: design a URL shortener like bitly for 100M users", "urlShortener"),
            ("Let's design the Twitter news feed with celebrity accounts", "newsFeed"),
            ("Design WhatsApp group chat with read receipts", "chat"),
            ("How would you build a rate limiter for our public API", "rateLimiter"),
            ("Design a distributed key value store like Dynamo", "keyValueStore"),
            ("Build a ride sharing service like Uber with driver matching", "rideSharing"),
            ("Design a payment system that avoids double charges", "payments"),
            ("Design Google Docs style collaborative editing", "collaborativeEditing")
        ]

        for testCase in cases {
            let detected = SystemDesignArchetypeCatalog.detect(in: testCase.transcript)
            XCTAssertEqual(detected?.id, testCase.expectedID, testCase.transcript)
        }
    }

    func testGenericTranscriptsDetectNothing() {
        XCTAssertNil(SystemDesignArchetypeCatalog.detect(in: "Let's talk about your background and experience"))
        XCTAssertNil(SystemDesignArchetypeCatalog.detect(in: ""))
        XCTAssertNil(SystemDesignArchetypeCatalog.detect(in: "Here's what was discussed: the weather"))
    }

    func testEveryArchetypeCarriesSignatureComponents() {
        for archetype in SystemDesignArchetypeCatalog.archetypes {
            XCTAssertFalse(archetype.keywords.isEmpty, archetype.id)
            XCTAssertGreaterThanOrEqual(archetype.signatureComponents.count, 3, archetype.id)
            XCTAssertLessThanOrEqual(archetype.signatureComponents.count, 5, archetype.id)
        }
        let ids = SystemDesignArchetypeCatalog.archetypes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Archetype ids must be unique")
    }

    func testUserPromptGainsArchetypeGuidance() {
        let prompt = PromptBuilder.buildSystemDesignUserPrompt(
            transcript: "Design a URL shortener like tinyurl",
            hasImages: false
        )

        XCTAssertTrue(prompt.contains("Detected problem archetype: URL shortener"))
        XCTAssertTrue(prompt.contains("base62 encoding"))
    }

    func testUserPromptWithoutArchetypeStaysClean() {
        let prompt = PromptBuilder.buildSystemDesignUserPrompt(
            transcript: "Please look at the problem on screen",
            hasImages: true
        )

        XCTAssertFalse(prompt.contains("Detected problem archetype"))
    }
}
