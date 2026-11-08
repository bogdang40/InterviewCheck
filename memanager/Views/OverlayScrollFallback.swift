import AppKit

/// Picks the scroll view a hotkey should move when no registered scroll
/// target claimed the event. Pure geometry so the choice can be tested:
/// the largest visible scroll view wins, with a bonus for centred views
/// when Quick Assist is the preferred target, and ties broken by width
/// then by leftmost origin.
enum OverlayScrollFallback {
    static func scrollView(in rootView: NSView, preferredTarget: ScrollTarget) -> NSScrollView? {
        let candidates = collectScrollViews(in: rootView)
        guard !candidates.isEmpty else { return nil }

        let candidateRects = candidates.map { $0.convert($0.bounds, to: rootView) }
        guard let index = bestFallbackScrollViewIndex(
            rootBounds: rootView.bounds,
            candidateBoundsInRoot: candidateRects,
            preferredTarget: preferredTarget
        ) else {
            return nil
        }
        return candidates[index]
    }

    static func collectScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectScrollViews(in: subview))
        }
        return result
    }

    static func bestFallbackScrollViewIndex(
        rootBounds: CGRect,
        candidateBoundsInRoot: [CGRect],
        preferredTarget: ScrollTarget? = nil
    ) -> Int? {
        var bestIndex: Int?
        var bestScore: CGFloat = -.greatestFiniteMagnitude
        var bestWidth: CGFloat = 0
        var bestMinX: CGFloat = 0

        for (index, rect) in candidateBoundsInRoot.enumerated() {
            let visible = rect.intersection(rootBounds)
            guard !visible.isNull, !visible.isEmpty else { continue }

            let width = visible.width
            let minX = visible.minX
            let score = fallbackScore(for: visible, in: rootBounds, preferredTarget: preferredTarget)

            let isFirst = bestIndex == nil
            let scoresHigher = score > bestScore + 0.5
            let tiesOnScore = abs(score - bestScore) <= 0.5
            let isWider = width > bestWidth + 0.5
            let tiesOnWidth = abs(width - bestWidth) <= 0.5
            let isFurtherLeft = minX < bestMinX - 0.5

            if isFirst || scoresHigher || (tiesOnScore && isWider) || (tiesOnScore && tiesOnWidth && isFurtherLeft) {
                bestIndex = index
                bestScore = score
                bestWidth = width
                bestMinX = minX
            }
        }

        return bestIndex
    }

    static func fallbackScore(
        for visibleRect: CGRect,
        in rootBounds: CGRect,
        preferredTarget: ScrollTarget?
    ) -> CGFloat {
        let area = visibleRect.width * visibleRect.height
        guard preferredTarget == .quickAssist else {
            return area
        }
        let centerDistance = abs(visibleRect.midX - rootBounds.midX)
        let centeredBonus = max(0, (rootBounds.width * 0.5) - centerDistance) * visibleRect.height * 0.25
        return area + centeredBonus
    }
}
