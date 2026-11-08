import Foundation

struct ProjectToolRootDescriptor: Equatable {
    let rootName: String
    let displayPath: String

    init(rootName: String, displayPath: String) {
        let trimmedPath = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = URL(fileURLWithPath: trimmedPath.isEmpty ? "/" : trimmedPath).lastPathComponent
        self.rootName = rootName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : rootName
        self.displayPath = trimmedPath
    }

    init(config: ProjectFolderConfig) {
        self.init(rootName: config.rootName, displayPath: config.displayPath)
    }

    init(rootURL: URL, config: ProjectFolderConfig) {
        let displayPath = config.displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootName = config.rootName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            rootName: rootName.isEmpty ? rootURL.lastPathComponent : rootName,
            displayPath: displayPath.isEmpty ? rootURL.path : displayPath
        )
    }

    var discoveryExample: String {
        #"list_directory(path: "")"#
    }

    var relativePathExample: String {
        "folder/file.ext"
    }

    var summaryLine: String {
        "Selected project root: \(rootName) at \(displayPath)"
    }
}
