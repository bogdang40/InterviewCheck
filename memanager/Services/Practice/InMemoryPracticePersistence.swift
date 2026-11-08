import Foundation

/// State-holding in-memory persistence used when the app target runs under
/// XCTest, so singleton-path tests never write to the real database.
final class InMemoryPracticePersistence: PracticePersisting {
    private var cards: [PracticeCard] = []
    private var schedules: [PracticeSchedule] = []
    private var reviews: [PracticeReview] = []

    func loadPracticeState() -> (cards: [PracticeCard], schedules: [PracticeSchedule], reviews: [PracticeReview]) {
        (cards, schedules, reviews)
    }

    func savePracticeCard(_ card: PracticeCard, schedule: PracticeSchedule) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }

        if let index = schedules.firstIndex(where: { $0.cardID == schedule.cardID }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    func savePracticeReview(_ review: PracticeReview, schedule: PracticeSchedule) {
        reviews.append(review)
        if let index = schedules.firstIndex(where: { $0.cardID == schedule.cardID }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    func archivePracticeCard(cardID: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isArchived = true
    }

    func clearPracticeData() {
        cards.removeAll()
        schedules.removeAll()
        reviews.removeAll()
    }
}
