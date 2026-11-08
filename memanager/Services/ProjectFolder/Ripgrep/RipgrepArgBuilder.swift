import Foundation

/// Renders `RipgrepService.SearchOptions` or `RipgrepService.FileListOptions`
/// into an argv array. Separated out so the serialization is unit testable in
/// isolation from process spawning.
enum RipgrepArgBuilder {
    static func searchArgs(_ opts: RipgrepService.SearchOptions) -> [String] {
        var args: [String] = [
            "--json",
            "--line-number",
            "--byte-offset",
            "--no-heading",
            "--color", "never",
            "--no-messages",
            "--max-count", String(opts.maxCount),
            "--max-filesize", String(opts.maxFileSizeBytes)
        ]
        if !opts.respectGitignore {
            args.append("--no-ignore")
        } else {
            args.append("--no-require-git")
        }
        if opts.includeHidden { args.append("--hidden") }
        if opts.caseSensitive {
            args.append("--case-sensitive")
        } else {
            args.append("--smart-case")
        }
        if opts.fixedStrings { args.append("--fixed-strings") }
        if opts.multiline {
            args.append("--multiline")
            args.append("--multiline-dotall")
        }
        if opts.contextBefore > 0 {
            args.append(contentsOf: ["--before-context", String(opts.contextBefore)])
        }
        if opts.contextAfter > 0 {
            args.append(contentsOf: ["--after-context", String(opts.contextAfter)])
        }
        for fileType in opts.fileTypes {
            args.append(contentsOf: ["--type", fileType])
        }
        args.append(contentsOf: ["--glob", "!.git/*"])
        args.append("--")
        args.append(opts.pattern)
        args.append(".")
        return args
    }

    static func filesArgs(_ opts: RipgrepService.FileListOptions) -> [String] {
        var args: [String] = [
            "--files",
            "--color", "never",
            "--no-messages"
        ]
        if !opts.respectGitignore {
            args.append("--no-ignore")
        } else {
            args.append("--no-require-git")
        }
        if opts.includeHidden { args.append("--hidden") }
        for fileType in opts.fileTypes {
            args.append(contentsOf: ["--type", fileType])
        }
        if let pattern = opts.pattern, !pattern.isEmpty {
            args.append(contentsOf: ["--glob", pattern])
        }
        args.append(contentsOf: ["--glob", "!.git/*"])
        args.append(".")
        return args
    }
}
