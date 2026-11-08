import AppKit
import SwiftUI

/// Shown in the main window until the app is unlocked: sign in or create an
/// account, subscribe, retry when the server is unreachable, or install an
/// owner license file.
struct AccessGateView: View {
    @ObservedObject var controller: AccessController
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var adminSecret = ""
    @State private var isCreatingAccount = false
    @State private var selectedPlan: String?
    @State private var isImportingLicense = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text(AppBrand.name).font(.largeTitle.weight(.semibold))
                content
                if let error = controller.errorMessage {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Divider().padding(.vertical, 4)
                HStack {
                    Button("Install Owner License\u{2026}") { isImportingLicense = true }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: 420)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $isImportingLicense, allowedContentTypes: [.data, .json]) { result in
            if case .success(let url) = result {
                Task { await controller.installOwnerLicense(from: url) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .checking, .allowed:
            ProgressView()
        case .signedOut:
            signIn
        case .paywall(let snapshot):
            paywall(snapshot)
        case .unreachable(let message):
            unreachable(message)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCreatingAccount ? "Create your account" : "Sign in to continue")
                .font(.title3.weight(.semibold))
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
            if isCreatingAccount {
                SecureField("Confirm password", text: $confirmPassword)
                Text("At least \(SignInFormRules.minimumPasswordLength) characters.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced") {
                    SecureField("Admin setup code (optional)", text: $adminSecret)
                }
            }
            HStack {
                Button(isCreatingAccount ? "Sign in instead" : "Create an account") {
                    isCreatingAccount.toggle()
                    controller.errorMessage = nil
                }
                .buttonStyle(.link)
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button(isCreatingAccount ? "Create Account" : "Sign In") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SignInFormRules.canSubmit(email: email, password: password,
                                                         confirmPassword: confirmPassword,
                                                         isCreatingAccount: isCreatingAccount,
                                                         isBusy: controller.isBusy))
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func paywall(_ snapshot: AccessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe to continue").font(.title3.weight(.semibold))
            Text(PaywallPresentation.statusLine(for: snapshot)).foregroundStyle(.secondary)
            if let plans = controller.plans, plans.configured, !plans.plans.isEmpty {
                Picker("Plan", selection: Binding(
                    get: { selectedPlan ?? PaywallPresentation.defaultSelection(in: plans.plans) },
                    set: { selectedPlan = $0 }
                )) {
                    ForEach(plans.plans, id: \.self) { Text(PaywallPresentation.planTitle($0)).tag(Optional($0)) }
                }
                .pickerStyle(.radioGroup)
                Text(PaywallPresentation.planCaption(selectedPlan ?? plans.plans[0]))
                    .font(.caption).foregroundStyle(.secondary)
            } else if controller.isLoadingPlans {
                ProgressView()
            } else if let error = controller.plansError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Sign Out") { Task { await controller.signOut() } }
                Button("Manage Billing") { Task { await controller.openBillingPortal() } }
                Spacer()
                if controller.isAwaitingCheckout {
                    ProgressView().controlSize(.small)
                    Text("Waiting for payment\u{2026}").foregroundStyle(.secondary)
                }
                Button("Subscribe") {
                    let plan = selectedPlan ?? controller.plans.flatMap { PaywallPresentation.defaultSelection(in: $0.plans) }
                    if let plan { Task { await controller.startCheckout(plan: plan) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.plans?.plans.isEmpty ?? true)
            }
        }
        .task { await controller.loadPlans() }
    }

    private func unreachable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Can't reach the account server", systemImage: "wifi.exclamationmark")
                .font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            Text("Server: \(AccessServerAddress.current())").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Sign Out") { Task { await controller.signOut() } }
                Spacer()
                Button("Try Again") { Task { await controller.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func submit() {
        Task {
            if isCreatingAccount {
                await controller.signUp(email: email, password: password,
                                        adminSecret: adminSecret.isEmpty ? nil : adminSecret)
            } else {
                await controller.signIn(email: email, password: password)
            }
        }
    }
}
