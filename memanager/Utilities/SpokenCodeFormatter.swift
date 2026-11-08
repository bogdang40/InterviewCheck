import Foundation

struct SpokenCodeFormatter {
    enum Style {
        case mixed
        case literal
    }

    private enum Token {
        case whitespace(String)
        case identifier(String)
        case number(String)
        case stringLiteral(String)
        case `operator`(String)
        case punctuation(String)
    }

    private static let multiCharOperators = [
        ">>=", "<<=", "==", "!=", ">=", "<=", "++", "--", "->", "::",
        "<<", ">>", "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=",
        "^=", "??", "?.", "=>", "===","!=="
    ]

    private static let singleCharOperators: Set<Character> = [
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~", "?"
    ]

    private static let punctuationChars: Set<Character> = [
        "(", ")", "{", "}", "[", "]", ";", ":", ",", "."
    ]

    private static let cppKeywords: [String: String] = [
        "include": "include",
        "using": "using",
        "namespace": "namespace",
        "std": "ess tee dee",
        "cout": "see-out",
        "cin": "see-in",
        "endl": "end line",
        "return": "return",
        "int": "int",
        "double": "double",
        "float": "float",
        "string": "string",
        "bool": "bool",
        "if": "if",
        "else": "else",
        "for": "for",
        "while": "while",
        "auto": "auto",
        "const": "const"
    ]

    private static let pythonKeywords: [String: String] = [
        "def": "def",
        "return": "return",
        "import": "import",
        "from": "from",
        "as": "as",
        "if": "if",
        "elif": "else if",
        "else": "else",
        "for": "for",
        "while": "while",
        "in": "in",
        "True": "true",
        "False": "false",
        "None": "none"
    ]

    private static let jsKeywords: [String: String] = [
        "function": "function",
        "const": "const",
        "let": "let",
        "var": "var",
        "return": "return",
        "if": "if",
        "else": "else",
        "for": "for",
        "while": "while",
        "null": "null",
        "undefined": "undefined",
        "true": "true",
        "false": "false"
    ]

    static func format(_ code: String, language: String, style: Style) -> String {
        let tokens = tokenize(code)
        let mapping = keywordMapping(for: language)
        let identifiers = tokens.compactMap { token -> String? in
            if case let .identifier(value) = token { return value.lowercased() }
            return nil
        }
        let hasCout = identifiers.contains("cout") || identifiers.contains("cerr") || identifiers.contains("clog")
        let hasCin = identifiers.contains("cin")

        var parts: [String] = []
        parts.reserveCapacity(tokens.count)

        for token in tokens {
            switch token {
            case .whitespace:
                continue
            case .identifier(let value):
                if let mapped = mapping[value] {
                    parts.append(mapped)
                } else {
                    parts.append(spellIdentifier(value))
                }
            case .number(let value):
                parts.append(value)
            case .stringLiteral(let value):
                parts.append("string \(value)")
            case .operator(let value):
                parts.append(spokenOperator(
                    value,
                    style: style,
                    language: language,
                    hasCout: hasCout,
                    hasCin: hasCin
                ))
            case .punctuation(let value):
                parts.append(spokenPunctuation(value, style: style))
            }
        }

        return parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keywordMapping(for language: String) -> [String: String] {
        switch language.lowercased() {
        case "cpp", "c++", "cxx":
            return cppKeywords
        case "python", "py":
            return pythonKeywords
        case "javascript", "js", "typescript", "ts":
            return jsKeywords
        default:
            return [:]
        }
    }

    private static func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        var index = code.startIndex

        func advance() {
            index = code.index(after: index)
        }

        while index < code.endIndex {
            let char = code[index]

            if char.isWhitespace {
                var buffer = String(char)
                advance()
                while index < code.endIndex, code[index].isWhitespace {
                    buffer.append(code[index])
                    advance()
                }
                tokens.append(.whitespace(buffer))
                continue
            }

            if char == "\"" || char == "'" {
                let delimiter = char
                var buffer = ""
                advance()
                while index < code.endIndex {
                    let current = code[index]
                    if current == "\\" {
                        buffer.append(current)
                        advance()
                        if index < code.endIndex {
                            buffer.append(code[index])
                            advance()
                        }
                        continue
                    }
                    if current == delimiter {
                        advance()
                        break
                    }
                    buffer.append(current)
                    advance()
                }
                tokens.append(.stringLiteral(buffer))
                continue
            }

            if char.isNumber {
                var buffer = String(char)
                advance()
                while index < code.endIndex {
                    let current = code[index]
                    if current.isNumber || current == "." {
                        buffer.append(current)
                        advance()
                    } else {
                        break
                    }
                }
                tokens.append(.number(buffer))
                continue
            }

            if char.isLetter || char == "_" {
                var buffer = String(char)
                advance()
                while index < code.endIndex {
                    let current = code[index]
                    if current.isLetter || current.isNumber || current == "_" {
                        buffer.append(current)
                        advance()
                    } else {
                        break
                    }
                }
                tokens.append(.identifier(buffer))
                continue
            }

            if let op = matchMultiOperator(in: code, from: index) {
                tokens.append(.operator(op.value))
                index = op.nextIndex
                continue
            }

            if singleCharOperators.contains(char) {
                tokens.append(.operator(String(char)))
                advance()
                continue
            }

            if punctuationChars.contains(char) {
                tokens.append(.punctuation(String(char)))
                advance()
                continue
            }

            tokens.append(.punctuation(String(char)))
            advance()
        }

        return tokens
    }

    private static func matchMultiOperator(in code: String, from index: String.Index) -> (value: String, nextIndex: String.Index)? {
        for op in multiCharOperators.sorted(by: { $0.count > $1.count }) {
            guard let end = code.index(index, offsetBy: op.count, limitedBy: code.endIndex) else { continue }
            if code[index..<end] == op {
                return (op, end)
            }
        }
        return nil
    }

    private static func spokenOperator(
        _ value: String,
        style: Style,
        language: String,
        hasCout: Bool,
        hasCin: Bool
    ) -> String {
        let loweredLanguage = language.lowercased()
        let isCpp = loweredLanguage == "cpp" || loweredLanguage == "c++" || loweredLanguage == "cxx"

        if style == .mixed, isCpp {
            if value == "<<", hasCout {
                return "stream out"
            }
            if value == ">>", hasCin {
                return "stream in"
            }
        }

        switch value {
        case "::": return style == .literal ? "colon colon" : "scope"
        case "->": return style == .literal ? "dash greater than" : "arrow"
        case "<<": return style == .literal ? "less than less than" : "shift left"
        case ">>": return style == .literal ? "greater than greater than" : "shift right"
        case "==": return "equals equals"
        case "===": return "triple equals"
        case "!=": return "not equals"
        case "!==": return "not equals equals"
        case ">=": return "greater than or equal"
        case "<=": return "less than or equal"
        case "&&": return "and and"
        case "||": return "or or"
        case "+=": return "plus equals"
        case "-=": return "minus equals"
        case "*=": return "times equals"
        case "/=": return "divide equals"
        case "%=": return "mod equals"
        case "&=": return "and equals"
        case "|=": return "or equals"
        case "^=": return "xor equals"
        case "++": return "plus plus"
        case "--": return "minus minus"
        case "+": return "plus"
        case "-": return "minus"
        case "*": return "times"
        case "/": return "divide"
        case "%": return "mod"
        case "=": return "equals"
        case "<": return "less than"
        case ">": return "greater than"
        case "!": return "bang"
        case "&": return "ampersand"
        case "|": return "pipe"
        case "^": return "caret"
        case "~": return "tilde"
        case "?": return "question mark"
        case "=>": return "arrow"
        case "??": return "null coalescing"
        case "?.": return "optional chaining"
        default: return value
        }
    }

    private static func spokenPunctuation(_ value: String, style: Style) -> String {
        switch value {
        case "(": return "open paren"
        case ")": return "close paren"
        case "{": return "open brace"
        case "}": return "close brace"
        case "[": return "open bracket"
        case "]": return "close bracket"
        case ";": return "semicolon"
        case ":": return "colon"
        case ",": return "comma"
        case ".": return style == .literal ? "dot" : "dot"
        default: return value
        }
    }

    private static func spellIdentifier(_ value: String) -> String {
        if value.uppercased() == value, value.count <= 4 {
            return value.map { String($0).lowercased() }.joined(separator: " ")
        }

        let parts = splitIdentifier(value)
        guard !parts.isEmpty else { return value }
        return parts.joined(separator: " ")
    }

    private static func splitIdentifier(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""

        for char in value {
            if char == "_" {
                if !current.isEmpty {
                    parts.append(current.lowercased())
                    current = ""
                }
                continue
            }

            if char.isUppercase && !current.isEmpty {
                parts.append(current.lowercased())
                current = String(char)
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            parts.append(current.lowercased())
        }

        return parts
    }
}
