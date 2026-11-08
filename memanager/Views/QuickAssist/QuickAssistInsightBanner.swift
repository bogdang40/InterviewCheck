import SwiftUI

/// The single banner above the composer. Silent insights render nothing so
/// the calm state stays calm.
struct QuickAssistInsightBanner: View {
    let insight: QuickAssistPrimaryInsight
    let onAction: (QuickAssistPrimaryInsightAction) -> Void

    var body: some View {
        if !insight.isSilent {
            ToneBanner(
                tone: insight.tone,
                title: insight.title,
                message: insight.message,
                actions: bannerActions
            )
        }
    }

    private var bannerActions: [BannerAction] {
        var actions: [BannerAction] = []
        if let label = insight.primaryActionLabel, let action = insight.primaryAction {
            actions.append(BannerAction(title: label, kind: .secondary) { onAction(action) })
        }
        if let label = insight.secondaryActionLabel, let action = insight.secondaryAction {
            actions.append(BannerAction(title: label, kind: .ghost) { onAction(action) })
        }
        return actions
    }
}
