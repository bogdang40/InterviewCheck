import Foundation
import Network

/// A byte stream to an IMAP server (TLS in the app, scripted in tests).
protocol IMAPStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next bytes from the server; throws when the connection closes.
    func receive() async throws -> Data
    func close()
}

enum IMAPError: Error, Equatable {
    case rejected(status: String, message: String)
    case closed
    case tooLarge
}

/// One IMAP conversation: reads whole responses (literals included) and
/// sends tagged commands. Used by one task at a time.
final class IMAPSession {
    private let stream: IMAPStream
    private var buffer: [UInt8] = []
    private var tagNumber = 0
    /// A single literal larger than this is refused (a calendar part is a few kB).
    static let maxLiteral = 8 * 1024 * 1024

    init(stream: IMAPStream) {
        self.stream = stream
    }

    /// The server's first line: "* OK" (or "* PREAUTH").
    func greeting() async throws {
        let line = String(decoding: try await readLine(), as: UTF8.self).uppercased()
        guard line.hasPrefix("* OK") || line.hasPrefix("* PREAUTH") else {
            throw IMAPError.rejected(status: "BYE", message: line)
        }
    }

    /// Sends a command and returns its untagged responses; a NO or BAD throws.
    @discardableResult
    func command(_ text: String) async throws -> [Data] {
        tagNumber += 1
        let tag = "A\(tagNumber)"
        try await stream.send(Data("\(tag) \(text)\r\n".utf8))
        var untagged: [Data] = []
        let prefix = Array("\(tag) ".utf8)
        while true {
            let line = try await readLine()
            if line.starts(with: prefix) {
                let rest = String(decoding: line.dropFirst(prefix.count), as: UTF8.self)
                let status = String(rest.prefix { $0 != " " }).uppercased()
                if status == "OK" { return untagged }
                throw IMAPError.rejected(status: status,
                                         message: String(rest.dropFirst(status.count)).trimmingCharacters(in: .whitespaces))
            }
            untagged.append(line)
        }
    }

    func close() { stream.close() }

    /// One response line with any `{n}` literals inlined, without the final CRLF.
    func readLine() async throws -> Data {
        var scanFrom = 0
        while true {
            if let crlf = Self.crlf(in: buffer, from: scanFrom) {
                if let count = Self.literalCount(in: buffer, endingAt: crlf, from: scanFrom) {
                    guard count <= Self.maxLiteral else { throw IMAPError.tooLarge }
                    let needed = crlf + 2 + count
                    while buffer.count < needed { try await fill() }
                    scanFrom = needed
                    continue
                }
                let line = Data(buffer[0..<crlf])
                buffer.removeFirst(crlf + 2)
                return line
            }
            try await fill()
        }
    }

    private func fill() async throws {
        let data = try await stream.receive()
        guard !data.isEmpty else { throw IMAPError.closed }
        buffer.append(contentsOf: data)
    }

    private static func crlf(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A { return index }
            index += 1
        }
        return nil
    }

    /// `{123}` or `{123+}` right before the line break.
    private static func literalCount(in bytes: [UInt8], endingAt end: Int, from start: Int) -> Int? {
        guard end > start, bytes[end - 1] == 0x7D else { return nil }
        var index = end - 2
        var digits: [UInt8] = []
        if index >= start, bytes[index] == 0x2B { index -= 1 }
        while index >= start, (0x30...0x39).contains(bytes[index]) {
            digits.insert(bytes[index], at: 0)
            index -= 1
        }
        guard index >= start, bytes[index] == 0x7B, !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// A quoted IMAP string. Line breaks and non-ASCII text cannot be quoted.
    static func quoted(_ value: String) throws -> String {
        guard value.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) else {
            throw ConnectorError.unsupported("Mail sign-in only accepts plain letters, digits and symbols. Use an app password.")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// IMAP's search date ("7-Nov-2026").
    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }
}

/// IMAP over TLS with Network.framework.
final class NetworkIMAPStream: IMAPStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "interviewcheck.imap")
    private let timeout: TimeInterval

    init(host: String, port: UInt16, timeout: TimeInterval = 30) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: .tls)
        self.timeout = timeout
    }

    func open() async throws {
        let once = ResumeOnce()
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error):
                        once.run { continuation.resume(throwing: ConnectorError.http(0, "Could not reach the mail server (\(error.localizedDescription))")) }
                    case .waiting(let error):
                        once.run { continuation.resume(throwing: ConnectorError.http(0, "Could not reach the mail server (\(error.localizedDescription))")) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: IMAPError.closed) }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }

    func receive() async throws -> Data {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    continuation.resume(throwing: IMAPError.closed)
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    /// Cancels the connection when a step takes too long, which ends the step with an error.
    private func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = timeout
        let connection = self.connection
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                connection.cancel()
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw ConnectorError.http(0, "The mail server stopped answering")
            }
            return value
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
