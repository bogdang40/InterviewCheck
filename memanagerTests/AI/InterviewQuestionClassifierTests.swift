import XCTest
@testable import memanager

final class InterviewQuestionClassifierTests: XCTestCase {

    private let classifier = InterviewQuestionClassifier()

    private func classify(
        question: String,
        transcript: String = "",
        extraContext: String = "",
        source: QuickAssistQuestionSource = .manual,
        previousFamilyID: String? = nil,
        allowed: Set<String>? = nil,
        fallback: String? = nil
    ) -> InterviewFamilyResolution? {
        classifier.classify(
            InterviewQuestionClassifier.Input(
                question: question,
                transcript: transcript,
                extraContext: extraContext,
                questionSource: source,
                previousFamilyID: previousFamilyID,
                allowedFamilyIDs: allowed,
                defaultFamilyID: fallback
            )
        )
    }

    func testDetectsTheInterviewCanon() {
        let cases: [(question: String, expectedID: String)] = [
            ("Can you walk me through your resume?", "self_intro"),
            ("Tell me about yourself", "self_intro"),
            ("Why do you want to work here?", "motivation"),
            ("Tell me about a time you disagreed with your manager", "behavioral_story"),
            ("What is your biggest weakness?", "weakness_growth"),
            ("What are your strengths?", "strengths_pitch"),
            ("What would you do if two deadlines collide?", "hypothetical_situational"),
            ("How do you handle an underperformer on your team?", "people_management"),
            ("Write a function to reverse a linked list", "coding_algorithm"),
            ("What is wrong with this code?", "debugging_code_review"),
            ("Write a query to find the top salary per department", "sql_data"),
            ("What is the difference between TCP and UDP?", "knowledge_concept"),
            ("How would you design a URL shortener?", "system_design"),
            ("Design a parking lot with multiple vehicle types", "api_object_design"),
            ("How would you design a recommendation system for videos?", "ml_system_design"),
            ("You get paged at 3am because latency spiked, walk me through it", "incident_response"),
            ("What is the probability of two dice summing to seven?", "stats_probability"),
            ("How would you design an experiment to test the new signup flow?", "ab_testing"),
            ("DAU dropped by ten percent last week, how do you investigate?", "analytics_case"),
            ("How would you improve Google Maps?", "product_sense"),
            ("What metrics would you use to measure success of Stories?", "product_metrics"),
            ("How many piano tuners are there in Chicago?", "estimation"),
            ("Should we enter the grocery delivery market?", "business_case"),
            ("What are your salary expectations?", "salary_comp"),
            ("Do you have any questions for us?", "reverse_questions"),
            ("What is your notice period?", "logistics_close"),
            ("Sell me this pen", "brainteaser")
        ]

        for testCase in cases {
            let resolution = classify(question: testCase.question)
            XCTAssertEqual(resolution?.playbook.id, testCase.expectedID, testCase.question)
            XCTAssertFalse(resolution?.isProbe ?? true, testCase.question)
        }
    }

    func testResumeWalkthroughNeverRoutesToCoding() {
        let resolution = classify(question: "Walk me through your resume")
        XCTAssertEqual(resolution?.playbook.id, "self_intro")
        XCTAssertEqual(resolution?.playbook.voiceStyle, .spoken)
        XCTAssertFalse(resolution?.playbook.allowsCode ?? true)
    }

    func testSurvivesTranscriptionFiller() {
        let resolution = classify(
            question: "",
            transcript: "Speaker 1: so um tell me about a time you uh disagreed with a coworker"
        )
        XCTAssertEqual(resolution?.playbook.id, "behavioral_story")
    }

    func testFallsBackToTranscriptWhenQuestionEmpty() {
        let resolution = classify(
            question: "",
            transcript: "Me: happy to.\nSpeaker 1: what are your salary expectations for this role"
        )
        XCTAssertEqual(resolution?.playbook.id, "salary_comp")
    }

    func testSupportingContextScoresLowerThanPrimary() {
        let resolution = classify(
            question: "",
            transcript: "Speaker 1: let's design a url shortener\nMe: sure, sounds good"
        )
        XCTAssertEqual(resolution?.playbook.id, "system_design")
        XCTAssertLessThan(resolution?.confidence ?? 1.0, 0.84)
    }

    func testProbeDetectionInheritsPreviousFamily() {
        let resolution = classify(
            question: "Why did you choose that approach?",
            previousFamilyID: "behavioral_story"
        )
        XCTAssertEqual(resolution?.playbook.id, "follow_up_probe")
        XCTAssertTrue(resolution?.isProbe ?? false)
        XCTAssertEqual(resolution?.secondaryFamilyID, "behavioral_story")
    }

    func testShortAnaphoricFollowUpIsProbe() {
        let resolution = classify(
            question: "And how did it perform?",
            previousFamilyID: "project_deep_dive"
        )
        XCTAssertEqual(resolution?.playbook.id, "follow_up_probe")
        XCTAssertTrue(resolution?.isProbe ?? false)
    }

    func testProbeCuesWithoutPreviousTurnDoNotResolve() {
        XCTAssertNil(classify(question: "Tell me more"))
    }

    func testFreshStrongQuestionBeatsProbeHeuristic() {
        let resolution = classify(
            question: "Tell me about a time you failed",
            previousFamilyID: "system_design"
        )
        XCTAssertEqual(resolution?.playbook.id, "behavioral_story")
        XCTAssertFalse(resolution?.isProbe ?? true)
    }

    func testCompoundQuestionYieldsSecondaryFamily() {
        let resolution = classify(
            question: "Tell me about a project you led and what metrics would you use to measure success"
        )
        XCTAssertEqual(resolution?.playbook.id, "project_deep_dive")
        XCTAssertEqual(resolution?.secondaryFamilyID, "product_metrics")
    }

    func testBehaviouralRestrictionBlocksTechnicalHijack() {
        let resolution = classify(
            question: "How would you design better teamwork rituals?",
            allowed: InterviewPlaybookCatalog.spokenFamilyIDs,
            fallback: "behavioral_story"
        )
        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.playbook.voiceStyle, .spoken)
    }

    func testRestrictionFallsBackToDefaultFamily() {
        let resolution = classify(
            question: "Something totally unrelated to any cue list",
            allowed: InterviewPlaybookCatalog.spokenFamilyIDs,
            fallback: "behavioral_story"
        )
        XCTAssertEqual(resolution?.playbook.id, "behavioral_story")
        XCTAssertEqual(resolution?.confidence ?? 0, 0.6, accuracy: 0.001)
    }

    func testNoTextAndNoFallbackResolvesNil() {
        XCTAssertNil(classify(question: "   "))
        XCTAssertNil(classify(question: "Something totally unrelated to any cue list"))
    }

    func testSignalsCarryFamilyBreadcrumbs() {
        let resolution = classify(question: "Tell me about a time you missed a deadline")
        XCTAssertEqual(resolution?.playbook.id, "behavioral_story")
        XCTAssertTrue(resolution?.signals.contains("family=behavioral_story") ?? false)
        XCTAssertTrue(resolution?.signals.contains(where: { $0.hasPrefix("family_cue=") }) ?? false)
    }
}
