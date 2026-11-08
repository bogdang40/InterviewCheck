import Foundation

/// Tolerant parser that turns the LLM's raw response into a `SessionSummary`. Strips common
/// code fence wrappers, finds the first JSON object, and decodes best effort.
enum SessionSummaryJSONParser {
    struct ParsedPayload: Decodable {
        struct Item: Decodable {
            let title: String
            let owner: String?
            let dueDate: String?
            let notes: String?
        }
        let actionItems: [Item]
        let backgroundSummary: String
        let followUpEmail: String?
    }

    enum ParseError: Error, LocalizedError {
        case noJSONObjectFound
        case decodeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noJSONObjectFound:
                return "No JSON object was found in the LLM response."
            case .decodeFailed(let err):
                return "JSON could not be decoded: \(err.localizedDescription)"
            }
        }
    }

    static func parse(rawResponse: String) throws -> ParsedPayload {
        let stripped = stripFences(rawResponse)
        guard let objectSubstring = firstJSONObjectSubstring(in: stripped) else {
            throw ParseError.noJSONObjectFound
        }
        let data = Data(objectSubstring.utf8)
        do {
            return try JSONDecoder().decode(ParsedPayload.self, from: data)
        } catch {
            throw ParseError.decodeFailed(error)
        }
    }

    static func makeSummary(sessionID: UUID, from payload: ParsedPayload) -> SessionSummary {
        let actionItems = payload.actionItems.map { item in
            SessionSummary.ActionItem(
                title: item.title,
                owner: item.owner,
                dueDate: item.dueDate,
                notes: item.notes
            )
        }
        return SessionSummary(
            sessionID: sessionID,
            status: .completed,
            actionItems: actionItems,
            backgroundSummary: payload.backgroundSummary,
            followUpEmailDraft: payload.followUpEmail,
            generatedAt: Date(),
            errorMessage: nil
        )
    }

    // MARK: - Helpers

    private static func stripFences(_ text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.hasPrefix("```") {
            working = working.replacingOccurrences(of: "```json", with: "")
            working = working.replacingOccurrences(of: "```", with: "")
            working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return working
    }

    private static func firstJSONObjectSubstring(in text: String) -> String? {
        guard let openIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var currentIndex = openIndex
        while currentIndex < text.endIndex {
            let character = text[currentIndex]
            if escape {
                escape = false
            } else if character == "\\" && inString {
                escape = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let endIndex = text.index(after: currentIndex)
                        return String(text[openIndex..<endIndex])
                    }
                }
            }
            currentIndex = text.index(after: currentIndex)
        }
        return nil
    }
}
