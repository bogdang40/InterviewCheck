import Foundation

/// Preserves environment, permission checked file, then Keychain precedence.
/// Both file and Keychain reads are called only by CachedCredential workers.
final class ProviderCredentials {
    private let credentials: [AIProviderType: CachedCredential<String>]
    var onChange: (() -> Void)?

    init() {
        credentials = Dictionary(uniqueKeysWithValues: AIProviderType.allCases.map { provider in
            let key = "memanager.apiKey.\(provider.rawValue)"
            return (provider, CachedCredential<String>(
                read: { try Self.resolve(provider: provider, key: key) },
                write: { value in
                    let saved = try CredentialKeychain.writeString(value, key: key)
                    return Self.override(for: provider) ?? saved
                }
            ))
        })
        for credential in credentials.values {
            credential.onChange = { [weak self] in self?.onChange?() }
        }
    }

    func reload() { credentials.values.forEach { $0.reload() } }
    func value(for provider: AIProviderType) -> String { credentials[provider]?.value ?? "" }
    func status(for provider: AIProviderType) -> CredentialStatus { credentials[provider]?.status ?? .loading }
    func save(_ key: String, for provider: AIProviderType) { credentials[provider]?.save(key) }

    static func resolve(
        provider: AIProviderType,
        key: String,
        environment: [String: String] = TestRuntime.isRunningUnitTests ? [:] : ProcessInfo.processInfo.environment,
        fileValue: (String) -> String? = readFileValue,
        keychainValue: (String) throws -> String? = CredentialKeychain.readString
    ) throws -> String? {
        let name = environmentName(for: provider)
        if let value = CredentialKeychain.normalized(environment[name]) { return value }
        if let value = CredentialKeychain.normalized(fileValue(name)) { return value }
        return CredentialKeychain.normalized(try keychainValue(key))
    }

    private static func override(for provider: AIProviderType) -> String? {
        guard !TestRuntime.isRunningUnitTests else { return nil }
        let name = environmentName(for: provider)
        return CredentialKeychain.normalized(ProcessInfo.processInfo.environment[name])
            ?? CredentialKeychain.normalized(readFileValue(name))
    }

    private static func environmentName(for provider: AIProviderType) -> String {
        switch provider {
        case .claude: return "MEMANAGER_CLAUDE_API_KEY"
        case .openai: return "MEMANAGER_OPENAI_API_KEY"
        case .azureOpenAI: return "MEMANAGER_AZURE_API_KEY"
        }
    }

    private static func readFileValue(_ name: String) -> String? {
        guard !TestRuntime.isRunningUnitTests else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".memanager/keys.env")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] as? NSNumber,
           !KeysFileAccess.isPermissionSafe(mode: permissions.uint16Value) {
            return nil
        }
        guard let contents = try? String(contentsOf: url) else { return nil }
        return KeysFileAccess.value(for: name, contents: contents)
    }
}
