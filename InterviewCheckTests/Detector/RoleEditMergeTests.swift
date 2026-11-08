import XCTest
@testable import InterviewCheck

final class RoleEditMergeTests: XCTestCase {
    func testBackgroundDraftSurvivesAnOpenEditor() {
        let base = RoleProfile(name: "Backend Engineer", jobDescription: "Payments API.")
        var latest = base
        latest.plannedQuestions = [PlannedQuestion(text: "Design a rate limiter", strongAnswer: "")]
        latest.updatedAt = Date().addingTimeInterval(5)
        var local = base
        local.company = "Acme"

        let merged = RoleEditMerge.merge(local: local, base: base, latest: latest)
        XCTAssertEqual(merged.plannedQuestions.count, 1, "the drafted questions are kept")
        XCTAssertEqual(merged.company, "Acme", "the interviewer's edit is kept")

        var edited = base
        edited.plannedQuestions = [PlannedQuestion(text: "My own question", strongAnswer: "")]
        XCTAssertEqual(RoleEditMerge.merge(local: edited, base: base, latest: latest).plannedQuestions.map(\.text),
                       ["My own question"], "a field the interviewer changed wins")
        XCTAssertTrue(RoleEditMerge.sameContent(latest, { var copy = latest; copy.updatedAt = .distantPast; return copy }()))
    }
}
