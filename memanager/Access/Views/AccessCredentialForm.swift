import SwiftUI

/// Email and password fields with the sign in or create account action.
/// Credentials go straight to the access server; nothing is stored locally
/// except the returned session token in the Keychain. Used by the gate and
/// by the Account page (an owner unlocked by license still signs in here
/// to manage accounts).
struct AccessCredentialForm: View {
    @ObservedObject var controller: AccessController
    @Binding var isCreatingAccount: Bool

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var adminSecret = ""
    @State private var showsOwnerSetup = false

    private var canSubmit: Bool {
        SignInFormRules.canSubmit(
            email: email,
            password: password,
            confirmPassword: confirmPassword,
            isCreatingAccount: isCreatingAccount,
            isBusy: controller.isBusy
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(spacing: DesignTokens.Spacing.md) {
                AccessFormField(label: "Email", placeholder: "you@example.com", text: $email, contentType: .username)
                AccessFormField(
                    label: "Password",
                    placeholder: "At least \(SignInFormRules.minimumPasswordLength) characters",
                    text: $password,
                    isSecure: true,
                    contentType: isCreatingAccount ? .newPassword : .password
                )
                if isCreatingAccount {
                    AccessFormField(
                        label: "Confirm password",
                        placeholder: "Repeat the password",
                        text: $confirmPassword,
                        isSecure: true,
                        contentType: .newPassword
                    )
                    DisclosureCard("Owner setup (optional)", systemImage: "key", isExpanded: $showsOwnerSetup) {
                    AccessFormField(
                        label: "Admin setup key",
                        placeholder: "Optional",
                        text: $adminSecret,
                        isSecure: true,
                        helper: "Owner only. Leave empty otherwise."
                    )
                    }
                }
            }
            .onSubmit(submit)

            if let message = controller.errorMessage {
                ToneBanner(tone: .critical, message: message)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Button(action: submit) {
                    HStack(spacing: 6) {
                        Text(isCreatingAccount ? "Create account" : "Sign in")
                        KeyCap(shortcut: "Return", emphasized: true)
                    }
                }
                .buttonStyle(.overlayPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)

                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(isCreatingAccount ? "Back to sign in" : "Create account") {
                    isCreatingAccount.toggle()
                    controller.errorMessage = nil
                }
                .buttonStyle(.overlay(.ghost, size: .small))
                .disabled(controller.isBusy)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if isCreatingAccount {
                await controller.signUp(email: trimmedEmail, password: password, adminSecret: adminSecret.isEmpty ? nil : adminSecret)
            } else {
                await controller.signIn(email: trimmedEmail, password: password)
            }
        }
    }
}
