import XCTest
@testable import InterviewCheck

final class InterviewPlaybookCatalogTests: XCTestCase {

    func testCatalogInvariants() {
        let playbooks = InterviewPlaybookCatalog.playbooks
        XCTAssertGreaterThanOrEqual(playbooks.count, 25, "The catalog must cover the interview canon")

        let ids = playbooks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Playbook ids must be unique")

        for playbook in playbooks {
            XCTAssertFalse(playbook.displayName.isEmpty, playbook.id)
            XCTAssertFalse(playbook.frameworkName.isEmpty, playbook.id)
            XCTAssertFalse(playbook.frameworkSummary.isEmpty, playbook.id)
            XCTAssertFalse(playbook.strongCues.isEmpty, playbook.id)
            XCTAssertFalse(playbook.spokenLengthTarget.isEmpty, playbook.id)
            if playbook.id != InterviewPlaybookCatalog.followUpProbe.id {
                XCTAssertGreaterThanOrEqual(playbook.beats.count, 3, playbook.id)
                XCTAssertLessThanOrEqual(playbook.beats.count, 6, playbook.id)
                for beat in playbook.beats {
                    XCTAssertTrue(beat.contains(":"), "Beat must be Label: guidance in \(playbook.id)")
                }
            }
        }
    }

    func testSpokenFamiliesNeverAllowCodeOrDiagrams() {
        for playbook in InterviewPlaybookCatalog.playbooks where playbook.voiceStyle == .spoken {
            XCTAssertFalse(playbook.allowsCode, playbook.id)
            XCTAssertFalse(playbook.allowsMermaid, playbook.id)
        }
    }

    func testLookupRoundTrips() {
        for playbook in InterviewPlaybookCatalog.playbooks {
            XCTAssertEqual(InterviewPlaybookCatalog.playbook(id: playbook.id)?.id, playbook.id)
        }
        XCTAssertNil(InterviewPlaybookCatalog.playbook(id: "missing_family"))
    }

    func testPromptContractCarriesSpineAndFramework() {
        for playbook in InterviewPlaybookCatalog.playbooks {
            let contract = playbook.promptContract
            XCTAssertTrue(contract.contains(InterviewAnswerPlaybook.sayFirstLabel), playbook.id)
            XCTAssertTrue(contract.contains(playbook.frameworkName), playbook.id)
            XCTAssertTrue(contract.contains(playbook.spokenLengthTarget), playbook.id)
            XCTAssertTrue(contract.contains("Depth policy:"), playbook.id)
        }
    }

    func testProbeContractDemandsDeltaAnswer() {
        let contract = InterviewPlaybookCatalog.followUpProbe.promptContract
        XCTAssertTrue(contract.contains("Do NOT restart with a fresh structure"))
        XCTAssertTrue(contract.contains("three to six speakable sentences"))
        XCTAssertFalse(contract.contains("### <beat label>"))
    }

    func testBeatContractsNumberEveryBeat() {
        guard let star = InterviewPlaybookCatalog.playbook(id: "behavioral_story") else {
            return XCTFail("behavioral_story missing")
        }
        let contract = star.promptContract
        for (index, beat) in star.beats.enumerated() {
            XCTAssertTrue(contract.contains("\(index + 1). \(beat)"), beat)
        }
    }

    func testRequiredElementKeysDeriveFromBeatLabels() {
        guard let star = InterviewPlaybookCatalog.playbook(id: "behavioral_story") else {
            return XCTFail("behavioral_story missing")
        }
        XCTAssertEqual(
            star.requiredElementKeys,
            ["beat_situation", "beat_task", "beat_action", "beat_result", "beat_lesson"]
        )
        XCTAssertEqual(star.outputContract.requiredElements, star.requiredElementKeys)
        XCTAssertTrue(star.outputContract.enforceFirstPerson)
    }

    func testLegacyIntentMappingStaysWithinKnownIntents() {
        for playbook in InterviewPlaybookCatalog.playbooks {
            XCTAssertNotEqual(playbook.legacyIntent, .projectBrief, "Project brief is tool driven, never family driven: \(playbook.id)")
        }
    }
}
