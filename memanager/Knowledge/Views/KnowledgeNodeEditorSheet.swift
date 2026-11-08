import SwiftUI

/// Create or edit a single fact by hand.
struct KnowledgeNodeEditorSheet: View {
    let node: KnowledgeNode?
    let onSave: (KnowledgeNode) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: KnowledgeNodeKind
    @State private var label: String
    @State private var summary: String
    @State private var propertiesText: String
    @State private var errorMessage: String?

    init(node: KnowledgeNode?, onSave: @escaping (KnowledgeNode) throws -> Void) {
        self.node = node
        self.onSave = onSave
        _kind = State(initialValue: node?.kind ?? .story)
        _label = State(initialValue: node?.label ?? "")
        _summary = State(initialValue: node?.summary ?? "")
        _propertiesText = State(initialValue: KnowledgeNodeEditorSheet.formatProperties(node?.properties ?? [:]))
    }

    var body: some View {
        OverlaySheetFrame(
            title: node == nil ? "New fact" : "Edit fact",
            subtitle: "A short canonical name, what it is in a sentence or two, and any properties worth citing.",
            width: 480,
            primaryTitle: "Save",
            isPrimaryEnabled: canSave,
            onPrimary: save,
            onCancel: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    LabeledField("Kind") {
                        KnowledgeKindMenu(kind: $kind)
                    }
                    LabeledField("Label") {
                        OverlayTextInput(placeholder: "Stripe, Kafka migration, Go", text: $label)
                    }
                }
                LabeledField("Summary") {
                    OverlayTextEditor(placeholder: "One or two sentences Quick Assist can quote", text: $summary, height: 90)
                }
                LabeledField("Properties", hint: "One per line as key: value") {
                    OverlayTextEditor(placeholder: "team: Payments", text: $propertiesText, height: 70, font: OverlayType.mono)
                }
                if let errorMessage {
                    ToneBanner(tone: .critical, title: "Fact was not saved", message: errorMessage)
                }
            }
        }
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard canSave else { return }
        if let issue = Self.propertiesIssue(propertiesText) {
            errorMessage = issue
            return
        }
        var updated = node ?? KnowledgeNode(kind: kind, label: label, sourceKind: .manual)
        updated.kind = kind
        updated.label = label.trimmingCharacters(in: .whitespaces)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.summary = trimmedSummary.isEmpty ? nil : trimmedSummary
        updated.properties = KnowledgeNodeEditorSheet.parseProperties(propertiesText)
        do {
            try onSave(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func formatProperties(_ properties: [String: String]) -> String {
        properties
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    static func propertiesIssue(_ text: String) -> String? {
        var keys: Set<String> = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                return "Property on line \(index + 1) needs a colon between its key and value."
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return "Property on line \(index + 1) needs both a key and a value." }
            guard keys.insert(key).inserted else { return "Property \(key) appears more than once." }
        }
        return nil
    }

    static func parseProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
