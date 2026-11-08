import Foundation

/// The product's name in one place. "InterviewCheck" is a working name;
/// rename here, in Info.plist (CFBundleName / CFBundleDisplayName) and in
/// project.yml (bundle id) when the final name is chosen.
enum AppBrand {
    static let name = "InterviewCheck"
    /// Folder under ~/Library/Application Support (and ~/Library/Logs).
    static let storageFolder = "InterviewCheck"
    /// Hidden folder in the home directory (owner license, developer keys, caches).
    static let homeFolder = ".interviewcheck"
    /// Keychain service for saved API keys. Separate from the original app's.
    static let keychainService = "com.interviewcheck.api"
    /// Link scheme for the billing return page.
    static let urlScheme = "interviewcheck"
    /// Folder in Documents holding one folder per role.
    static let rolesFolder = "InterviewCheck Roles"
}
