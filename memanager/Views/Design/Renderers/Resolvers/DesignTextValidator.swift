import Foundation

/// Filters the malformed fragments the parser can hand a legacy block: blank
/// strings, placeholder rules made only of dash characters, and two
/// character stubs.
enum DesignTextValidator {
    private static let placeholderRule: Character = "-"

    static func isMeaningful(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        if trimmed.allSatisfy({ $0 == placeholderRule }) {
            return false
        }
        return trimmed.count > 2
    }
}
