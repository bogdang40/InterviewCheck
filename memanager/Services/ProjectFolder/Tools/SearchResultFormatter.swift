import Foundation

/// Renders `RipgrepMatch` rows into the compact text format the model expects.
/// Produces `path:line: text` on its own line, with optional context lines on
/// preceding and following lines prefixed with a space indent so the model can
/// see what surrounds the match without parsing anything.
struct SearchResultFormatter {
    struct Options {
        var showContext: Bool
        init(showContext: Bool = true) { self.showContext = showContext }
    }

    func format(_ matches: [RipgrepMatch], options: Options = Options()) -> String {
        var lines: [String] = []
        for match in matches {
            if options.showContext {
                for ctx in match.contextBefore {
                    lines.append("  \(match.relativePath):\(ctx.lineNumber): \(ctx.text)")
                }
            }
            lines.append("\(match.relativePath):\(match.lineNumber): \(match.lineText)")
            if options.showContext {
                for ctx in match.contextAfter {
                    lines.append("  \(match.relativePath):\(ctx.lineNumber): \(ctx.text)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
