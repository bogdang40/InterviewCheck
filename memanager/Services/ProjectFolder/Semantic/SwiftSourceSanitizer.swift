import Foundation

struct SwiftSourceSanitizer {
    struct State {
        var inBlockComment = false
    }

    mutating func sanitize(_ line: String, state: inout State) -> String {
        var output = ""
        var index = line.startIndex
        var inString = false

        while index < line.endIndex {
            let character = line[index]
            let nextIndex = line.index(after: index)
            let nextCharacter = nextIndex < line.endIndex ? line[nextIndex] : nil

            if state.inBlockComment {
                if character == "*", nextCharacter == "/" {
                    state.inBlockComment = false
                    index = line.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }

            if !inString, character == "/", nextCharacter == "*" {
                state.inBlockComment = true
                index = line.index(after: nextIndex)
                continue
            }
            if !inString, character == "/", nextCharacter == "/" {
                break
            }
            if character == "\"", !isEscaped(line: line, quoteIndex: index) {
                inString.toggle()
                output.append(" ")
                index = nextIndex
                continue
            }

            output.append(inString ? " " : character)
            index = nextIndex
        }

        return output
    }

    func braceDelta(in sanitizedLine: String) -> Int {
        sanitizedLine.reduce(into: 0) { delta, character in
            if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }
    }

    private func isEscaped(line: String, quoteIndex: String.Index) -> Bool {
        var backslashCount = 0
        var cursor = quoteIndex
        while cursor > line.startIndex {
            cursor = line.index(before: cursor)
            guard line[cursor] == "\\" else { break }
            backslashCount += 1
        }
        return backslashCount % 2 == 1
    }
}
