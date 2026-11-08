import CoreGraphics

/// Whether the streaming container keeps the newest text in view.
enum StreamingAutoScrollMode {
    case always
    case smart
}

/// How a programmatic scroll interacts with the user's own scrolling.
enum StreamingProgrammaticFollowPolicy {
    case lockDuringProgrammaticScroll
    case allowUserDetachment
}

/// Decides when the reader counts as "near the bottom".
struct StreamingAutoScrollPolicy {
    let nearBottomThreshold: CGFloat

    init(nearBottomThreshold: CGFloat = 56) {
        self.nearBottomThreshold = nearBottomThreshold
    }

    func isNearBottom(offsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        guard visibleHeight > 0 else { return true }
        let distanceFromBottom = max(0, contentHeight - (offsetY + visibleHeight))
        return distanceFromBottom <= nearBottomThreshold
    }
}

struct StreamingFollowState {
    let isFollowingLatest: Bool
    let isProgrammaticScroll: Bool
}

/// Pure reducer for the follow state so the detachment rules can be tested.
func reduceStreamingFollowState(
    autoScrollMode: StreamingAutoScrollMode,
    programmaticFollowPolicy: StreamingProgrammaticFollowPolicy,
    nearBottom: Bool,
    isProgrammaticScroll: Bool,
    isFollowingLatest: Bool
) -> StreamingFollowState {
    switch autoScrollMode {
    case .always:
        return StreamingFollowState(isFollowingLatest: true, isProgrammaticScroll: isProgrammaticScroll)
    case .smart:
        if isProgrammaticScroll {
            switch programmaticFollowPolicy {
            case .lockDuringProgrammaticScroll:
                return StreamingFollowState(isFollowingLatest: isFollowingLatest, isProgrammaticScroll: true)
            case .allowUserDetachment:
                if nearBottom {
                    return StreamingFollowState(isFollowingLatest: isFollowingLatest, isProgrammaticScroll: true)
                }
                return StreamingFollowState(isFollowingLatest: false, isProgrammaticScroll: false)
            }
        }
        return StreamingFollowState(isFollowingLatest: nearBottom, isProgrammaticScroll: false)
    }
}
