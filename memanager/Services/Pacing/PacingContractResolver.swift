import Foundation

/// Maps a `PacingState` onto a `QuickAssistOutputContract` override.
///
/// We only tune length-related fields (`detailLevel`, `responseShape`) so the
/// first-person voice and other hard rules stay invariant under pacing. The
/// resolver is a pure function; call `resolve(base:state:)` and consume the
/// returned override or the original base contract.
enum PacingContractResolver {

    static func resolve(base: QuickAssistOutputContract, state: PacingState) -> QuickAssistOutputContract {
        guard state.confidence >= 0.25 else { return base }
        switch state.kind {
        case .decisive, .stalled:
            return QuickAssistOutputContract(
                detailLevel: .concise,
                enforceFirstPerson: base.enforceFirstPerson,
                responseShape: base.responseShape,
                requiredElements: base.requiredElements
            )
        case .measured:
            return base
        case .expansive:
            return QuickAssistOutputContract(
                detailLevel: .detailed,
                enforceFirstPerson: base.enforceFirstPerson,
                responseShape: base.responseShape,
                requiredElements: base.requiredElements
            )
        }
    }
}
