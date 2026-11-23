import Foundation

/// Reads the judge's "likelihood" strictly: one whole number from 0 to 100,
/// as a JSON number or a string holding only that number. Ranges ("70-80"),
/// fractions ("0.7"), words and out of range values are no signal at all,
/// rather than digits glued together into a different number.
enum JudgeLikelihood {
    static let range = 0...100

    static func parse(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber {
            return parse(number)
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit), let value = Int(trimmed) else { return nil }
            return range.contains(value) ? value : nil
        }
        return nil
    }

    private static func parse(_ number: NSNumber) -> Int? {
        // JSON true and false arrive as NSNumber too.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, let whole = Int(exactly: value) else { return nil }
        return range.contains(whole) ? whole : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
