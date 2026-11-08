import SwiftUI

/// The interviewer's own notes on one answer, saved as they type. Give each
/// question its own field (`.id(questionID)`) so a note never lands on the
/// wrong question.
struct QuestionNoteField: View {
    let questionID: String
    var database: SessionDatabase = .shared
    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        TextField("Your notes", text: $text, prompt: Text("Your notes on this answer"), axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Your notes on this answer")
            .onAppear {
                saved = database.loadAnswerNote(questionID: questionID)
                text = saved
            }
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                save()
            }
            .onDisappear(perform: save)
    }

    private func save() {
        guard text != saved else { return }
        database.saveAnswerNote(text, questionID: questionID)
        saved = text
    }
}
