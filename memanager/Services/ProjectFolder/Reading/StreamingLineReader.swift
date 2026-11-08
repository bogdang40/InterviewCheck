import Foundation

/// Buffered line reader with offset, limit, and byte budget. Opens the file via
/// `FileHandle` and reads in 64 KB chunks, splitting on LF and preserving CR so
/// CRLF files round trip. Stops at whichever limit fires first.
struct StreamingLineReader {
    struct Output: Equatable {
        let lines: [String]
        let startLine: Int
        let endLine: Int
        let totalLines: Int?
        let cut: Bool
        let more: Bool
    }

    enum ReaderError: Error, LocalizedError {
        case cannotOpen(String)
        case decodeFailed(Int)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path):
                return "Could not open file: \(path)"
            case .decodeFailed(let offset):
                return "File is not valid UTF 8 near byte offset \(offset)."
            }
        }
    }

    private static let chunkSize = 64 * 1024
    private static let maxLineLength = 4000
    private static let truncationSuffix = "...<line truncated>"

    let url: URL
    let offset: Int
    let limit: Int
    let byteBudget: Int

    func read() throws -> Output {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReaderError.cannotOpen(url.path)
        }
        defer { try? handle.close() }

        var lines: [String] = []
        var currentLineBytes: [UInt8] = []
        var linesSeen = 0
        var emittedBytes = 0
        var cut = false
        var more = false
        let startAt = max(offset, 1)
        var firstEmitted: Int? = nil

        readLoop: while true {
            let chunk = nextChunk(handle)
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 0x0A {
                    linesSeen += 1
                    let rawLine = makeString(currentLineBytes)
                    currentLineBytes.removeAll(keepingCapacity: true)
                    guard let text = rawLine else {
                        throw ReaderError.decodeFailed(emittedBytes)
                    }
                    if linesSeen < startAt { continue }
                    if lines.count >= limit {
                        more = true
                        continue readLoop
                    }
                    let truncated = truncateLine(text)
                    let size = estimatedBytes(truncated, isFirst: lines.isEmpty)
                    if emittedBytes + size > byteBudget {
                        cut = true
                        more = true
                        break readLoop
                    }
                    if firstEmitted == nil { firstEmitted = linesSeen }
                    lines.append(truncated)
                    emittedBytes += size
                } else {
                    currentLineBytes.append(byte)
                }
            }
        }

        if !currentLineBytes.isEmpty {
            linesSeen += 1
            if linesSeen >= startAt, lines.count < limit, let text = makeString(currentLineBytes) {
                let truncated = truncateLine(text)
                let size = estimatedBytes(truncated, isFirst: lines.isEmpty)
                if emittedBytes + size <= byteBudget {
                    if firstEmitted == nil { firstEmitted = linesSeen }
                    lines.append(truncated)
                    emittedBytes += size
                } else {
                    cut = true
                    more = true
                }
            } else if linesSeen >= startAt, lines.count >= limit {
                more = true
            }
        }

        let endLine = firstEmitted.map { $0 + lines.count - 1 } ?? startAt - 1
        let totalLines: Int? = more ? nil : linesSeen
        return Output(
            lines: lines,
            startLine: firstEmitted ?? startAt,
            endLine: max(endLine, firstEmitted ?? startAt - 1),
            totalLines: totalLines,
            cut: cut,
            more: more
        )
    }

    private func nextChunk(_ handle: FileHandle) -> Data {
        if #available(macOS 10.15.4, *) {
            return (try? handle.read(upToCount: Self.chunkSize)) ?? Data()
        }
        return handle.readData(ofLength: Self.chunkSize)
    }

    private func makeString(_ bytes: [UInt8]) -> String? {
        if bytes.isEmpty { return "" }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func truncateLine(_ text: String) -> String {
        if text.count <= Self.maxLineLength { return text }
        return String(text.prefix(Self.maxLineLength)) + Self.truncationSuffix
    }

    private func estimatedBytes(_ text: String, isFirst: Bool) -> Int {
        let base = text.utf8.count
        return isFirst ? base : base + 1
    }
}
