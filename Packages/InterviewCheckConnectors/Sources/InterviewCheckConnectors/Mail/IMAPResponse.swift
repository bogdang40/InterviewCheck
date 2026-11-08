import Foundation

/// One value in an IMAP response (RFC 9051 / 3501): an atom, a string
/// (quoted or a `{n}` literal), NIL, or a parenthesized list.
enum IMAPValue: Equatable {
    case atom(String)
    case string(Data)
    case none
    case list([IMAPValue])

    /// Atoms and strings as text; NIL and lists as nil.
    var text: String? {
        switch self {
        case .atom(let value): return value
        case .string(let data): return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        default: return nil
        }
    }

    var items: [IMAPValue]? {
        if case .list(let values) = self { return values }
        return nil
    }
}

/// Splits one logical IMAP response line (literals already inlined) into values.
enum IMAPParser {
    static func values(_ data: Data) -> [IMAPValue] {
        var stack: [[IMAPValue]] = [[]]
        let bytes = [UInt8](data)
        var position = 0
        func append(_ value: IMAPValue) { stack[stack.count - 1].append(value) }
        while position < bytes.count {
            let byte = bytes[position]
            switch byte {
            case 0x20, 0x0D, 0x0A:
                position += 1
            case 0x28: // (
                stack.append([])
                position += 1
            case 0x29: // )
                position += 1
                if stack.count > 1 {
                    let list = stack.removeLast()
                    append(.list(list))
                }
            case 0x22: // "quoted"
                position += 1
                var value = [UInt8]()
                while position < bytes.count, bytes[position] != 0x22 {
                    if bytes[position] == 0x5C, position + 1 < bytes.count { position += 1 }
                    value.append(bytes[position])
                    position += 1
                }
                position += 1
                append(.string(Data(value)))
            case 0x7B: // {n} literal, followed by CRLF and n bytes
                var end = position + 1
                while end < bytes.count, bytes[end] != 0x7D { end += 1 }
                let digits = String(decoding: bytes[(position + 1)..<min(end, bytes.count)], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
                let count = Int(digits) ?? 0
                var start = end + 1
                if start < bytes.count, bytes[start] == 0x0D { start += 1 }
                if start < bytes.count, bytes[start] == 0x0A { start += 1 }
                let stop = min(start + count, bytes.count)
                append(.string(Data(bytes[start..<stop])))
                position = stop
            default:
                var end = position
                // An atom runs to a space or bracket; BODY[1.2] keeps its brackets.
                var depth = 0
                while end < bytes.count {
                    let next = bytes[end]
                    if next == 0x5B { depth += 1 } else if next == 0x5D { depth -= 1 }
                    if depth <= 0, next == 0x20 || next == 0x28 || next == 0x29 || next == 0x0D || next == 0x0A { break }
                    end += 1
                }
                let word = String(decoding: bytes[position..<end], as: UTF8.self)
                append(word.uppercased() == "NIL" ? .none : .atom(word))
                position = end
            }
        }
        while stack.count > 1 {
            let list = stack.removeLast()
            stack[stack.count - 1].append(.list(list))
        }
        return stack[0]
    }

    /// The attribute list of a `* n FETCH (...)` response as name → value.
    static func fetchAttributes(_ line: Data) -> [String: IMAPValue]? {
        let values = values(line)
        guard values.count >= 4, values[0].text == "*", values[2].text?.uppercased() == "FETCH",
              let items = values[3].items else { return nil }
        var attributes: [String: IMAPValue] = [:]
        var index = 0
        while index + 1 < items.count {
            if let name = items[index].text { attributes[name.uppercased()] = items[index + 1] }
            index += 2
        }
        return attributes
    }

    /// The numbers of a `* SEARCH 1 2 3` response.
    static func searchResults(_ line: Data) -> [Int]? {
        let values = values(line)
        guard values.count >= 2, values[0].text == "*", values[1].text?.uppercased() == "SEARCH" else { return nil }
        return values.dropFirst(2).compactMap { $0.text.flatMap(Int.init) }
    }
}

/// The parts of a message worth downloading, found in its BODYSTRUCTURE.
enum IMAPBodyStructure {
    struct Part: Equatable {
        /// The section to fetch ("1", "2.3").
        var section: String
        /// BASE64, QUOTED-PRINTABLE, 7BIT, 8BIT.
        var encoding: String
        var charset: String?
    }

    /// Calendar invites: text/calendar, application/ics, or any part named *.ics.
    static func calendarParts(_ body: IMAPValue) -> [Part] {
        var found: [Part] = []
        walk(body, path: [], found: &found)
        return found
    }

    private static func walk(_ body: IMAPValue, path: [Int], found: inout [Part]) {
        guard let items = body.items, !items.isEmpty else { return }
        if items.first?.items != nil {
            // Multipart: the children come first, then the subtype.
            var child = 0
            for item in items where item.items != nil {
                child += 1
                walk(item, path: path + [child], found: &found)
            }
            return
        }
        guard items.count >= 7 else { return }
        let type = items[0].text?.lowercased() ?? ""
        let subtype = items[1].text?.lowercased() ?? ""
        let params = parameters(items[2])
        let named = ([params["name"]] + items.dropFirst(7).flatMap(strings)).compactMap { $0 }
            .contains { $0.lowercased().hasSuffix(".ics") }
        let isCalendar = (type == "text" && subtype == "calendar") || (type == "application" && subtype == "ics") || named
        guard isCalendar else { return }
        found.append(Part(section: path.isEmpty ? "1" : path.map(String.init).joined(separator: "."),
                          encoding: items[5].text?.uppercased() ?? "7BIT", charset: params["charset"]))
    }

    private static func parameters(_ value: IMAPValue) -> [String: String] {
        guard let items = value.items else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text?.lowercased(), let value = items[index + 1].text { result[key] = value }
            index += 2
        }
        return result
    }

    private static func strings(_ value: IMAPValue) -> [String] {
        if let items = value.items { return items.flatMap(strings) }
        return value.text.map { [$0] } ?? []
    }
}

/// Undoes a MIME content-transfer-encoding.
enum MIMEDecoding {
    static func decode(_ data: Data, encoding: String, charset: String?) -> String? {
        let raw: Data
        switch encoding.uppercased() {
        case "BASE64":
            let compact = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) else { return nil }
            raw = decoded
        case "QUOTED-PRINTABLE":
            raw = quotedPrintable(data)
        default:
            raw = data
        }
        let latin = ["iso-8859-1", "latin1", "us-ascii", "windows-1252"].contains(charset?.lowercased() ?? "")
        if latin { return String(data: raw, encoding: .windowsCP1252) ?? String(data: raw, encoding: .isoLatin1) }
        return String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1)
    }

    static func quotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x37
            case 0x61...0x66: return byte - 0x57
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x3D else { output.append(byte); index += 1; continue }
            // "=" then CRLF (or LF) is a soft line break; "=XX" is one byte.
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
            if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
            if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
                continue
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }
}
