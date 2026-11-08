import SwiftUI

/// Server-provided plans and payment verification remain inside the access overlay.
struct PaywallView: View {
    @ObservedObject var controller: AccessController
    let snapshot: AccessSnapshot
    @State private var selectedPlan: String?

    private var offeredPlans: [String] {
        guard let plans = controller.plans, plans.configured else { return [] }
        return plans.plans
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            SurfaceHeader(
                controller.isAwaitingCheckout ? "Payment confirmation" : "Choose a plan",
                subtitle: controller.isAwaitingCheckout
                    ? "Access opens after the server confirms your entitlement."
                    : PaywallPresentation.statusLine(for: snapshot)
            )
            if controller.isAwaitingCheckout {
                ToneBanner(tone: .info, title: "Waiting for server confirmation",
                           message: "Returning from checkout does not confirm access. We will check again while this screen is open.",
                           systemImage: "hourglass")
            } else {
                planSelection
            }
            if let message = controller.errorMessage {
                ToneBanner(tone: .critical, title: "Could not complete the request", message: message)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Button(controller.isAwaitingCheckout ? "Check again" : "I already paid, check again") {
                    Task { await controller.refresh() }
                }
                .buttonStyle(.overlay(.secondary, size: .small))
                .disabled(controller.isBusy)
                if snapshot.subscription != nil {
                    Button("Manage existing billing") { Task { await controller.openBillingPortal() } }
                        .buttonStyle(.overlay(.secondary, size: .small))
                        .disabled(controller.isBusy)
                }
            }
            Hairline()
            HStack {
                Text(snapshot.user.email)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Sign out") { Task { await controller.signOut() } }
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
            Text("Checkout and billing open in your browser.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if controller.plans == nil { await controller.loadPlans() } }
        .onAppear(perform: preselect)
        .onChange(of: controller.plans) { _, _ in preselect() }
    }

    @ViewBuilder
    private var planSelection: some View {
        if let error = controller.plansError {
            ToneBanner(tone: .critical, title: "Plans could not be loaded", message: error,
                       actions: [BannerAction(title: "Retry") { Task { await controller.loadPlans() } }])
        }
        if controller.isLoadingPlans {
            ProgressCaption(text: "Loading available plans")
        } else if controller.plans != nil && offeredPlans.isEmpty {
            ToneBanner(tone: .warning, title: "No plans available",
                       message: "The access server has no configured plans. An administrator can review your access.")
        }
        if !offeredPlans.isEmpty {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(offeredPlans, id: \.self) { plan in
                    PaywallPlanRow(plan: plan, isSelected: plan == selectedPlan) { selectedPlan = plan }
                }
            }
            Button(action: subscribe) {
                Label("Continue to checkout", systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.overlayPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.isBusy || !offeredPlans.contains(selectedPlan ?? ""))
            Text("Available plans are supplied by your access server.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
    }

    private func preselect() {
        guard selectedPlan == nil || !offeredPlans.contains(selectedPlan ?? "") else { return }
        selectedPlan = PaywallPresentation.defaultSelection(in: offeredPlans)
    }

    private func subscribe() {
        guard !controller.isBusy, let plan = selectedPlan, offeredPlans.contains(plan) else { return }
        Task { await controller.startCheckout(plan: plan) }
    }
}

struct PaywallPlanRow: View {
    let plan: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        SelectableRow(isSelected: isSelected, action: onSelect) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? OverlayPalette.accent : OverlayPalette.textSecondary)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(PaywallPresentation.planTitle(plan))
                        .font(OverlayType.heading)
                        .foregroundStyle(OverlayPalette.textPrimary)
                    Text(PaywallPresentation.planCaption(plan))
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.sm)
        }
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
