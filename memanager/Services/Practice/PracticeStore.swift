import Combine
import Foundation

/// Observable practice deck store backed by SQLite in the app and by an
/// in-memory store under XCTest. The UI observes this singleton while tests can
/// inject a smaller persistence boundary.
protocol PracticeStoring: AnyObject {
    var cards: [PracticeCard] { get }
    var schedulesPublisher: Published<[PracticeSchedule]>.Publisher { get }
    var cardsPublisher: Published<[PracticeCard]>.Publisher { get }

    func insert(card: PracticeCard, schedule: PracticeSchedule)
    @discardableResult func record(review: PracticeReview, newSchedule: PracticeSchedule) -> Bool
    func dueCards(on date: Date) -> [(card: PracticeCard, schedule: PracticeSchedule)]
    func archive(cardID: String)
    func reset()
}

protocol PracticePersisting: AnyObject {
    func loadPracticeState() -> (cards: [PracticeCard], schedules: [PracticeSchedule], reviews: [PracticeReview])
    func savePracticeCard(_ card: PracticeCard, schedule: PracticeSchedule)
    func savePracticeReview(_ review: PracticeReview, schedule: PracticeSchedule) throws
    func archivePracticeCard(cardID: String)
    func clearPracticeData()
}

extension SessionLogger: PracticePersisting {}

final class PracticeStore: ObservableObject, PracticeStoring {
    static let shared = PracticeStore(persistence: makeDefaultPersistence())

    @Published private(set) var cards: [PracticeCard] = []
    @Published private(set) var schedules: [PracticeSchedule] = []
    @Published private(set) var reviews: [PracticeReview] = []
    @Published private(set) var lastError: String?

    var cardsPublisher: Published<[PracticeCard]>.Publisher { $cards }
    var schedulesPublisher: Published<[PracticeSchedule]>.Publisher { $schedules }

    private let persistence: PracticePersisting

    init(persistence: PracticePersisting = SessionLogger.shared) {
        self.persistence = persistence
        loadPersistedState()
    }

    private var scheduleIndex: [String: Int] {
        var out: [String: Int] = [:]
        for (index, schedule) in schedules.enumerated() {
            out[schedule.cardID] = index
        }
        return out
    }

    func insert(card: PracticeCard, schedule: PracticeSchedule) {
        cards.append(card)
        schedules.append(schedule)
        persistence.savePracticeCard(card, schedule: schedule)
    }

    @discardableResult
    func record(review: PracticeReview, newSchedule: PracticeSchedule) -> Bool {
        guard !reviews.contains(where: { $0.id == review.id }) else { return true }
        guard review.cardID == newSchedule.cardID,
              let current = schedules.first(where: { $0.cardID == review.cardID }),
              current.nextReviewAt <= review.reviewedAt else {
            lastError = "This card is no longer due. Its recorded schedule was retained."
            return false
        }
        do {
            try persistence.savePracticeReview(review, schedule: newSchedule)
        } catch {
            lastError = "Review was not saved: \(error.localizedDescription)"
            return false
        }
        lastError = nil
        reviews.append(review)
        if let index = scheduleIndex[newSchedule.cardID] {
            schedules[index] = newSchedule
        } else {
            schedules.append(newSchedule)
        }
        return true
    }

    func dueCards(on date: Date) -> [(card: PracticeCard, schedule: PracticeSchedule)] {
        let indexedSchedules = scheduleIndex
        return cards.compactMap { card -> (card: PracticeCard, schedule: PracticeSchedule)? in
            guard !card.isArchived,
                  let scheduleIdx = indexedSchedules[card.id]
            else { return nil }
            let schedule = schedules[scheduleIdx]
            guard schedule.nextReviewAt <= date else { return nil }
            return (card: card, schedule: schedule)
        }
    }

    func archive(cardID: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isArchived = true
        persistence.archivePracticeCard(cardID: cardID)
    }

    func reset() {
        cards.removeAll()
        schedules.removeAll()
        reviews.removeAll()
        persistence.clearPracticeData()
    }

    private func loadPersistedState() {
        let state = persistence.loadPracticeState()
        cards = state.cards
        schedules = state.schedules
        reviews = state.reviews
    }

    private static func makeDefaultPersistence() -> PracticePersisting {
        if TestRuntime.isRunningUnitTests {
            return InMemoryPracticePersistence()
        }
        return SessionLogger.shared
    }
}
