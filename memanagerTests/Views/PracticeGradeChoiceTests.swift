import XCTest
@testable import memanager

/// The four review choices, their SM2 mapping, interval previews, and the
/// session progress model.
final class PracticeGradeChoiceTests: XCTestCase {
    func testChoicesMapOntoSM2Grades() {
        XCTAssertEqual(PracticeGradeChoice.again.grade, .incorrectHardRecall)
        XCTAssertEqual(PracticeGradeChoice.hard.grade, .correctDifficult)
        XCTAssertEqual(PracticeGradeChoice.good.grade, .correctHesitation)
        XCTAssertEqual(PracticeGradeChoice.easy.grade, .perfect)
        XCTAssertEqual(PracticeGradeChoice.allCases.map(\.grade.rawValue), [1, 3, 4, 5])
    }

    func testEveryGradeFoldsBackIntoAChoice() {
        XCTAssertEqual(PracticeGradeChoice.choice(for: .blackout), .again)
        XCTAssertEqual(PracticeGradeChoice.choice(for: .incorrectEasyRecall), .again)
        XCTAssertEqual(PracticeGradeChoice.choice(for: .correctDifficult), .hard)
        XCTAssertEqual(PracticeGradeChoice.choice(for: .correctHesitation), .good)
        XCTAssertEqual(PracticeGradeChoice.choice(for: .perfect), .easy)
    }

    func testChoicesCarryNumberKeysInOrder() {
        XCTAssertEqual(PracticeGradeChoice.allCases.map(\.key), ["1", "2", "3", "4"])
        XCTAssertEqual(PracticeGradeChoice.allCases.map(\.title), ["Again", "Hard", "Good", "Easy"])
    }

    func testIntervalPreviewsUseSchedulerWithoutRecording() {
        let schedule = PracticeSchedule(cardID: "c", repetitionCount: 2, easiness: 2.5, intervalDays: 4)
        let previews = PracticeIntervalPreview.previews(for: schedule, scheduler: SM2PracticeScheduler(), now: Date())
        XCTAssertEqual(previews.map(\.choice), PracticeGradeChoice.allCases)
        XCTAssertEqual(previews.map(\.intervalDays), [1, 10, 10, 10])
        XCTAssertEqual(previews.map(\.label), ["1d", "10d", "10d", "10d"])
    }

    func testIntervalPreviewsForNewCardUseClampedFirstStep() {
        let previews = PracticeIntervalPreview.previews(for: PracticeSchedule(cardID: "c"), scheduler: SM2PracticeScheduler(), now: Date())
        XCTAssertEqual(previews.map(\.intervalDays), [1, 2, 2, 2])
        XCTAssertEqual(PracticeIntervalPreview.label(days: 0), "1d")
    }

    func testSessionProgressFractionAndLabel() {
        XCTAssertEqual(PracticeSessionProgress(graded: 0, due: 0).fraction, 0)
        XCTAssertEqual(PracticeSessionProgress(graded: 0, due: 0).label, "Deck clear")
        XCTAssertEqual(PracticeSessionProgress(graded: 3, due: 5).fraction, 0.375)
        XCTAssertEqual(PracticeSessionProgress(graded: 3, due: 5).label, "3 of 8 graded")
    }

    func testDifficultyAndEvaluationPresentation() {
        XCTAssertEqual(PracticeDifficulty.hard.tone, .critical)
        XCTAssertEqual(PracticeDifficulty.medium.title, "Medium")
        let passing = PracticeAttemptEvaluation(grade: .perfect, confidence: 80, feedback: "ok", attemptTranscript: "x")
        XCTAssertEqual(passing.tone, .success)
        XCTAssertEqual(passing.title, "Suggested: Perfect")
        let failing = PracticeAttemptEvaluation(grade: .blackout, confidence: 95, feedback: "no", attemptTranscript: "")
        XCTAssertEqual(failing.tone, .warning)
    }
}
