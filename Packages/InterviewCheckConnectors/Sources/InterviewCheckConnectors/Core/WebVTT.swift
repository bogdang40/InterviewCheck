import Foundation

/// A transcript line with timing and, when known, the speaker.
public struct TranscriptCue: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String?
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, speaker: String?, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// WebVTT as Teams (`<v Name>text</v>`) and Zoom (`Name: text`) write it.
public enum WebVTT {
    public static func cues(in text: String) -> [TranscriptCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block -> TranscriptCue? in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].components(separatedBy: " ").first ?? "") else { return nil }
            var body = lines[(timing + 1)...].joined(separator: " ")
            var speaker: String?
            if let voice = body.range(of: #"<v\s+([^>]+)>"#, options: .regularExpression) {
                speaker = String(body[voice]).replacingOccurrences(of: #"^<v\s+|>$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            body = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if speaker == nil, let colon = body.range(of: #"^[^:]{1,40}:\s"#, options: .regularExpression) {
                speaker = String(body[colon]).dropLast(2).trimmingCharacters(in: .whitespaces)
                body = String(body[colon.upperBound...])
            }
            guard !body.isEmpty else { return nil }
            return TranscriptCue(start: start, end: max(end, start), speaker: speaker, text: body)
        }
    }

    /// "00:01:02.500" or "01:02.500".
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), let last = Double(parts.last!) else { return nil }
        let numbers = parts.dropLast().compactMap(Double.init)
        guard numbers.count == parts.count - 1 else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 } * 60 + last
    }

    /// Writes cues back as WebVTT with voice tags.
    public static func text(_ cues: [TranscriptCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(stamp(cue.start)) --> \(stamp(cue.end))\n" + (cue.speaker.map { "<v \($0)>\(cue.text)</v>" } ?? cue.text)
        }.joined(separator: "\n\n") + "\n"
    }

    static func stamp(_ seconds: TimeInterval) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, (millis / 60_000) % 60, (millis / 1000) % 60, millis % 1000)
    }
}
