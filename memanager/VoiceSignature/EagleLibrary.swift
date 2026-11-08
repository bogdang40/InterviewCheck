import Foundation

/// Owns the dynamic library for the lifetime of its resolved C function table.
final class EagleLibrary {
    static let shared = EagleLibrary()
    private var handle: UnsafeMutableRawPointer?
    private(set) var symbols: EagleV3Symbols?
    private var loadError: EagleError = .sdkNotAvailable

    private init() {
        // Unit tests inject C symbols. Even frame-size queries must not load or
        // execute the user's SDK from a hosted test process.
        guard !TestRuntime.isRunningUnitTests else { return }
        for path in Self.searchPaths() where FileManager.default.fileExists(atPath: path) {
            guard let candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            do {
                symbols = try EagleV3Symbols { dlsym(candidate, $0) }
                handle = candidate
                return
            } catch {
                dlclose(candidate)
                loadError = (error as? EagleError) ?? .sdkNotAvailable
                // A bundled but incompatible SDK is a packaging error. Do not
                // silently substitute a different library from a developer path.
                return
            }
        }
    }

    func requireSymbols() throws -> EagleV3Symbols {
        guard let symbols else { throw loadError }
        return symbols
    }

    private static func searchPaths() -> [String] {
        [Bundle.main.privateFrameworksPath, Bundle.main.resourcePath]
            .compactMap { $0.map { "\($0)/libpv_eagle.dylib" } }
    }

    deinit {
        if let handle { dlclose(handle) }
    }
}
