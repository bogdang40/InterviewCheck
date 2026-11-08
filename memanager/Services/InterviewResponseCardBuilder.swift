import Foundation

protocol InterviewResponseCardBuilding {
    func buildCards(for moment: InterviewMoment) -> [ResponseCard]
}

struct InterviewResponseCardBuilder: InterviewResponseCardBuilding {
    func buildCards(for moment: InterviewMoment) -> [ResponseCard] {
        let templates = templates(for: moment.type)
        return templates.enumerated().map { index, template in
            ResponseCard(
                id: "\(moment.id)-\(index)",
                type: moment.type,
                shortLine: template.shortLine,
                expandedLine: template.expandedLine,
                teleprompterText: template.teleprompterText,
                sourceMomentID: moment.id,
                confidence: template.confidence,
                recommendedAction: template.recommendedAction,
                createdAt: moment.createdAt
            )
        }
    }

    private func templates(for type: ResponseCardType) -> [ResponseCardTemplate] {
        switch type {
        case .clarify:
            return [
                ResponseCardTemplate(
                    shortLine: "Clarify the constraint first",
                    expandedLine: "Ask for the missing constraint, then state the default assumption you would use if they want you to continue.",
                    teleprompterText: "Before I lock in an answer, I want to clarify the constraint that matters most here. If we assume the default case, I would proceed with...",
                    confidence: 0.88,
                    recommendedAction: .askClarifyingQuestion
                ),
                ResponseCardTemplate(
                    shortLine: "State one assumption out loud",
                    expandedLine: "Name the assumption that keeps your answer moving so the interviewer can correct it fast.",
                    teleprompterText: "I will assume the usual production constraint here unless you want a different target. Under that assumption, the cleanest approach is...",
                    confidence: 0.76,
                    recommendedAction: .refineInQuickAssist
                )
            ]
        case .tradeoff:
            return [
                ResponseCardTemplate(
                    shortLine: "Frame the tradeoff explicitly",
                    expandedLine: "Anchor the decision on what you are optimizing and what you are sacrificing.",
                    teleprompterText: "The tradeoff here is latency versus implementation complexity. I would optimize for the faster read path first because...",
                    confidence: 0.91,
                    recommendedAction: .explainTradeoff
                ),
                ResponseCardTemplate(
                    shortLine: "Tie the tradeoff to constraints",
                    expandedLine: "Explain why this tradeoff fits the current scale, reliability target, or team cost.",
                    teleprompterText: "Given the current constraints, I would accept the extra operational cost because it buys us the reliability we need at this scale.",
                    confidence: 0.79,
                    recommendedAction: .refineInQuickAssist
                )
            ]
        case .complexity:
            return [
                ResponseCardTemplate(
                    shortLine: "State time and space now",
                    expandedLine: "Close the loop by naming the asymptotic cost and the main driver of that cost.",
                    teleprompterText: "The runtime is linear in the input size and the extra space is constant aside from the output buffer.",
                    confidence: 0.9,
                    recommendedAction: .stateComplexity
                ),
                ResponseCardTemplate(
                    shortLine: "Call out the bottleneck",
                    expandedLine: "Name the operation that dominates the complexity so the interviewer sees the reasoning, not just the formula.",
                    teleprompterText: "The bottleneck is the full scan of the collection, so that is what drives the overall time complexity.",
                    confidence: 0.74,
                    recommendedAction: .refineInQuickAssist
                )
            ]
        case .pushback:
            return [
                ResponseCardTemplate(
                    shortLine: "Acknowledge and adjust",
                    expandedLine: "Validate the concern first, then show the concrete change you would make.",
                    teleprompterText: "That concern is fair. I would adjust the design by moving the state boundary and tightening the failure handling so...",
                    confidence: 0.9,
                    recommendedAction: .acknowledgePushback
                ),
                ResponseCardTemplate(
                    shortLine: "Offer a safer fallback",
                    expandedLine: "If the first plan is too risky, give the lower-risk fallback and why you would choose it.",
                    teleprompterText: "If we want the safer path, I would fall back to the simpler design first and accept the extra cost until the traffic justifies the more complex version.",
                    confidence: 0.77,
                    recommendedAction: .refineInQuickAssist
                )
            ]
        case .takeLead:
            return [
                ResponseCardTemplate(
                    shortLine: "Take the lead on next steps",
                    expandedLine: "Use the pause to restate assumptions and move the conversation forward.",
                    teleprompterText: "Let me make the next step concrete. I am assuming the common case, and under that assumption I would start by...",
                    confidence: 0.84,
                    recommendedAction: .takeLead
                ),
                ResponseCardTemplate(
                    shortLine: "Summarize and steer",
                    expandedLine: "Give a short recap and propose the next dimension you want to cover.",
                    teleprompterText: "So far we have the baseline approach. The next thing I would cover is the failure mode and how I would harden it.",
                    confidence: 0.72,
                    recommendedAction: .refineInQuickAssist
                )
            ]
        }
    }
}

private struct ResponseCardTemplate {
    let shortLine: String
    let expandedLine: String
    let teleprompterText: String
    let confidence: Double
    let recommendedAction: ResponseCardRecommendedAction
}
