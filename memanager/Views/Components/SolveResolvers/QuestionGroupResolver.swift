import Foundation

/// One group of clarifying questions with the number its first question
/// carries, so numbering runs continuously down the whole section.
struct QuestionGroup: Identifiable {
    let id: Question.QuestionCategory
    let title: String
    let systemImage: String
    let firstNumber: Int
    let questions: [Question]
}

/// Orders the three question groups the way the interviewer expects to
/// hear them and numbers the questions across groups. Pure so the
/// numbering can be tested without a view.
enum QuestionGroupResolver {
    static func groups(from content: QuestionsContent) -> [QuestionGroup] {
        let ordered: [(Question.QuestionCategory, String, [Question])] = [
            (.edgeCase, "Edge cases to clarify", content.edgeCaseQuestions),
            (.constraint, "Constraints to confirm", content.constraintQuestions),
            (.validation, "Input validation", content.validationQuestions)
        ]

        var nextNumber = 1
        var groups: [QuestionGroup] = []
        for (category, title, questions) in ordered where !questions.isEmpty {
            groups.append(
                QuestionGroup(
                    id: category,
                    title: title,
                    systemImage: category.icon,
                    firstNumber: nextNumber,
                    questions: questions
                )
            )
            nextNumber += questions.count
        }
        return groups
    }
}
