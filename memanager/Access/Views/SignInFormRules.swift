import Foundation

/// Pure validation for the sign in and create account form, mirroring the
/// server's minimums so a request that cannot succeed is never sent.
enum SignInFormRules {
    static let minimumPasswordLength = 10

    static func canSubmit(email: String, password: String, confirmPassword: String, isCreatingAccount: Bool, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), trimmedEmail.count >= 3, !trimmedEmail.hasPrefix("@"), !trimmedEmail.hasSuffix("@") else { return false }
        guard password.count >= minimumPasswordLength else { return false }
        return !isCreatingAccount || confirmPassword == password
    }
}
