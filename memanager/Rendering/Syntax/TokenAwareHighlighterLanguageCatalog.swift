import Foundation

/// Keyword tables for the languages interview candidates reach for beyond
/// the built in set. Kept apart from the highlighter so adding a language
/// never touches the tokenizer.
enum TokenAwareHighlighterLanguageCatalog {
    static func config(for language: String?) -> TokenAwareHighlighter.LanguageConfig? {
        switch language?.lowercased() {
        case "cpp", "c++", "cc", "cxx", "hpp", "c", "h":
            return cFamily
        case "java":
            return java
        case "csharp", "cs", "c#":
            return csharp
        case "kotlin", "kt", "kts":
            return kotlin
        default:
            return nil
        }
    }

    private static let cFamily = TokenAwareHighlighter.LanguageConfig(
        keywords: ["int", "long", "short", "char", "float", "double", "bool", "void", "auto",
                   "unsigned", "signed", "const", "constexpr", "static", "inline", "struct",
                   "class", "enum", "union", "namespace", "using", "template", "typename",
                   "public", "private", "protected", "virtual", "override", "final", "if",
                   "else", "for", "while", "do", "switch", "case", "default", "break",
                   "continue", "return", "new", "delete", "this", "nullptr", "true", "false",
                   "try", "catch", "throw", "sizeof", "include", "define", "std"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'"]
    )

    private static let java = TokenAwareHighlighter.LanguageConfig(
        keywords: ["abstract", "boolean", "break", "byte", "case", "catch", "char", "class",
                   "continue", "default", "do", "double", "else", "enum", "extends", "final",
                   "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
                   "interface", "long", "new", "package", "private", "protected", "public",
                   "record", "return", "short", "static", "super", "switch", "this", "throw",
                   "throws", "try", "var", "void", "volatile", "while", "true", "false", "null"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'"]
    )

    private static let csharp = TokenAwareHighlighter.LanguageConfig(
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch",
                   "char", "class", "const", "continue", "decimal", "default", "do", "double",
                   "else", "enum", "event", "finally", "float", "for", "foreach", "if", "in",
                   "int", "interface", "internal", "is", "long", "namespace", "new", "null",
                   "object", "out", "override", "private", "protected", "public", "readonly",
                   "ref", "return", "sealed", "static", "string", "struct", "switch", "this",
                   "throw", "try", "using", "var", "virtual", "void", "while", "yield",
                   "true", "false"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'"]
    )

    private static let kotlin = TokenAwareHighlighter.LanguageConfig(
        keywords: ["fun", "val", "var", "class", "object", "interface", "data", "sealed", "enum",
                   "if", "else", "when", "for", "while", "do", "return", "break", "continue",
                   "import", "package", "in", "is", "as", "null", "true", "false", "this",
                   "super", "override", "open", "abstract", "private", "public", "internal",
                   "protected", "suspend", "lateinit", "companion", "try", "catch", "finally",
                   "throw", "typealias", "by", "it"],
        lineCommentPrefix: "//",
        stringDelimiters: ["\"", "'"]
    )
}
