import Foundation

// MARK: - Protocol

protocol DebriefResponseParsing {
    func parse(
        response: String,
        sessionId: String,
        existingDebriefId: String?
    ) -> SessionDebrief?
}

// MARK: - Implementation

struct DebriefResponseParser: DebriefResponseParsing {

    func parse(
        response: String,
        sessionId: String,
        existingDebriefId: String?
    ) -> SessionDebrief? {
        guard let json = extractJSON(from: response) else {
            return nil
        }
        return buildDebrief(from: json, sessionId: sessionId, existingDebriefId: existingDebriefId)
    }

    // MARK: - JSON Extraction

    private func extractJSON(from text: String) -> [String: Any]? {
        let cleaned = stripMarkdownFences(text)

        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        if let range = cleaned.range(of: "{", options: .literal),
           let endRange = cleaned.range(of: "}", options: .backwards) {
            let substring = String(cleaned[range.lowerBound...endRange.upperBound])
            if let data = substring.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        return nil
    }

    private func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Debrief Construction

    private func buildDebrief(
        from json: [String: Any],
        sessionId: String,
        existingDebriefId: String?
    ) -> SessionDebrief? {
        let whatHappened = extractStringArray(json, key: "whatHappened")
        let strongMoments = extractStringArray(json, key: "strongMoments")
        let missedOpportunities = extractStringArray(json, key: "missedOpportunities")
        let recommendedDrills = extractStringArray(json, key: "recommendedDrills")
        let nextSessionFocus = extractStringArray(json, key: "nextSessionFocus")

        guard !whatHappened.isEmpty else { return nil }

        let debriefId = existingDebriefId ?? UUID().uuidString
        let now = Date()
        let drills = parseDrills(
            from: json,
            sessionId: sessionId,
            debriefId: debriefId
        )

        return SessionDebrief(
            id: debriefId,
            sessionId: sessionId,
            whatHappened: whatHappened,
            strongMoments: strongMoments,
            missedOpportunities: missedOpportunities,
            recommendedDrills: recommendedDrills,
            nextSessionFocus: nextSessionFocus,
            createdAt: now,
            updatedAt: now,
            drills: drills
        )
    }

    // MARK: - Drill Parsing

    private func parseDrills(
        from json: [String: Any],
        sessionId: String,
        debriefId: String
    ) -> [SessionDrill] {
        guard let rawDrills = json["drills"] as? [[String: Any]] else { return [] }

        let now = Date()
        return rawDrills.compactMap { raw in
            guard let kindRaw = raw["kind"] as? String,
                  let kind = SessionDrillKind(rawValue: kindRaw),
                  let title = raw["title"] as? String,
                  let prompt = raw["prompt"] as? String else {
                return nil
            }
            let relatedQuestion = raw["relatedTurnQuestion"] as? String ?? ""

            return SessionDrill(
                id: UUID().uuidString,
                sessionId: sessionId,
                debriefId: debriefId,
                kind: kind,
                title: title,
                prompt: prompt,
                transcriptSpan: relatedQuestion,
                relatedThreadId: nil,
                relatedTurnId: nil,
                createdAt: now
            )
        }
    }

    // MARK: - Helpers

    private func extractStringArray(_ json: [String: Any], key: String) -> [String] {
        (json[key] as? [String]) ?? []
    }
}
