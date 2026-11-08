import Foundation

extension ProjectSemanticQueryService {
    func typeRelationships(for name: String, path: String?) throws -> ProjectTypeRelationships {
        var declarations: [ProjectSymbolMatch] = []
        var extensions: [ProjectSymbolMatch] = []
        var inheritsFrom: [String] = []
        var conformsTo: [String] = []
        var conformers: [ProjectRelationshipConformer] = []
        var sawSemanticLanguage = false

        try enumerateFiles(in: path) { file in
            guard let scan = try scanFile(file) else { return true }
            sawSemanticLanguage = true
            for declaration in scan.declarations {
                if declaration.name == name {
                    let match = ProjectSymbolMatch(
                        kind: declaration.kind.rawValue,
                        name: declaration.name,
                        path: file.relativePath,
                        line: declaration.line,
                        signature: declaration.signature
                    )
                    if declaration.kind == .extension || declaration.kind == .impl {
                        extensions.append(match)
                        conformsTo.append(contentsOf: declaration.inheritedTypes)
                    } else {
                        declarations.append(match)
                        let split = splitRelationships(for: declaration)
                        inheritsFrom.append(contentsOf: split.inheritsFrom)
                        conformsTo.append(contentsOf: split.conformsTo)
                    }
                } else if declaration.inheritedTypes.contains(name) {
                    conformers.append(ProjectRelationshipConformer(
                        relation: relationLabel(for: declaration, subject: name),
                        kind: declaration.kind.rawValue,
                        name: declaration.name,
                        path: file.relativePath,
                        line: declaration.line
                    ))
                }
            }
            return true
        }

        return ProjectTypeRelationships(
            declarations: declarations.sorted(by: symbolSort),
            extensions: extensions.sorted(by: symbolSort),
            inheritsFrom: dedupe(inheritsFrom),
            conformsTo: dedupe(conformsTo),
            conformers: conformers.sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.path < rhs.path
            },
            note: sawSemanticLanguage ? nil : Self.supportedLanguageNote
        )
    }

    private func splitRelationships(for declaration: ProjectDeclaration) -> (inheritsFrom: [String], conformsTo: [String]) {
        switch declaration.kind {
        case .class:
            return (
                inheritsFrom: declaration.inheritedTypes.first.map { [$0] } ?? [],
                conformsTo: Array(declaration.inheritedTypes.dropFirst())
            )
        case .struct, .enum, .actor:
            return (inheritsFrom: [], conformsTo: declaration.inheritedTypes)
        case .protocol:
            return (inheritsFrom: declaration.inheritedTypes, conformsTo: [])
        case .trait:
            return (inheritsFrom: declaration.inheritedTypes, conformsTo: [])
        case .extension:
            return (inheritsFrom: [], conformsTo: declaration.inheritedTypes)
        case .impl:
            return (inheritsFrom: [], conformsTo: declaration.inheritedTypes)
        case .typealias, .function:
            return (inheritsFrom: [], conformsTo: [])
        }
    }

    private func relationLabel(for declaration: ProjectDeclaration, subject: String) -> String {
        if declaration.kind == .class, declaration.inheritedTypes.first == subject {
            return "inherits"
        }
        if declaration.kind == .protocol || declaration.kind == .trait {
            return "inherits"
        }
        if declaration.kind == .impl, declaration.inheritedTypes.contains(subject) {
            return "implements"
        }
        return "conforms"
    }
}
