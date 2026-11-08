import Foundation

/// Turns the controller's pipe delimited route summary ("Mode: Auto |
/// Resolved: Clarify | Intent: Clarify | Tier: FAST | ...") into a short
/// sentence fragment a person can read. Unknown keys are dropped; a summary
/// with nothing recognisable formats to nil so it is omitted, never shown raw.
enum QuickAssistRouteSummaryFormatter {
    static func format(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fields = parse(raw)
        var parts: [String] = []
        if let mode = fields["mode"] {
            if let resolved = fields["resolved"], resolved != mode {
                parts.append("Mode \(mode) resolved as \(resolved)")
            } else {
                parts.append("Mode \(mode)")
            }
        }
        if let intent = fields["intent"] {
            parts.append("Intent \(intent)")
        }
        if let tier = fields["tier"] {
            parts.append("Tier \(tier.capitalized)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func parse(_ raw: String) -> [String: String] {
        var fields: [String: String] = [:]
        for segment in raw.components(separatedBy: "|") {
            let pair = segment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, fields[key] == nil else { continue }
            fields[key] = value
        }
        return fields
    }
}
