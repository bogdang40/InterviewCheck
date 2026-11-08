import Foundation

/// Trust boundary for the plaintext ~/.memanager/keys.env developer
/// convenience file: permission checking and line parsing, pure and testable.
enum KeysFileAccess {
    /// A plaintext credentials file must be readable by its owner only.
    /// Group or other read bits fail the gate and the file is REFUSED, not
    /// merely warned about.
    static func isPermissionSafe(mode: UInt16) -> Bool {
        mode & 0o044 == 0
    }

    /// Extracts `keyName`'s value from KEY=VALUE lines, skipping blanks and
    /// `#` comments, trimming whitespace around names and values.
    static func value(for keyName: String, contents: String) -> String? {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            if name != keyName { continue }
            return String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
