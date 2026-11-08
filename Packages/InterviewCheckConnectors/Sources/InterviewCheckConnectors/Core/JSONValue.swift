import Foundation

/// Loosely typed JSON for mapping many vendors' responses without a Codable
/// struct per endpoint. Lookups never throw; missing values are nil.
public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public static func parse(_ data: Data) throws -> JSONValue {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ConnectorError.invalidResponse("not JSON")
        }
        return JSONValue(any: object)
    }

    public init(any value: Any) {
        switch value {
        case let dictionary as [String: Any]: self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case let array as [Any]: self = .array(array.map(JSONValue.init(any:)))
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        default: self = .null
        }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let dictionary) = self { return dictionary[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return .null
    }

    /// Follows a dotted path: "candidate.emails.0.value".
    public func at(_ path: String) -> JSONValue {
        path.split(separator: ".").reduce(self) { value, key in
            if let index = Int(key) { return value[index] }
            return value[String(key)]
        }
    }

    public var array: [JSONValue] {
        if case .array(let array) = self { return array }
        return []
    }

    public var string: String? {
        switch self {
        case .string(let string): return string.isEmpty ? nil : string
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let bool): return String(bool)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let number): return number
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Self when present, nil when null (for optional chaining).
    public var asObject: JSONValue? { isNull ? nil : self }

    public var date: Date? { string.flatMap(DateParsing.parse) }

    public var url: URL? { string.flatMap(URL.init(string:)) }

    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    var anyValue: Any {
        switch self {
        case .object(let dictionary): return dictionary.mapValues(\.anyValue)
        case .array(let array): return array.map(\.anyValue)
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// ISO 8601 with or without fractional seconds, plus plain dates.
public enum DateParsing {
    public static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        if let seconds = Double(string), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: string)
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func millis(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1000)) }
}
