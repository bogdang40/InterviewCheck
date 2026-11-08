import SwiftUI

extension ScoreBand {
    var color: Color {
        switch self {
        case .genuine: return .green
        case .mixed: return .orange
        case .flagged: return .red
        }
    }
}

/// The score for one answer: %, confidence, reasons, and follow-ups.
struct ScoreCard: View {
    let score: AnswerScoreRecord
    var showsFollowUps = true

    private var band: ScoreBand { ScoreBand(percent: score.percent) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(score.percent)%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(band.color)
                        .accessibilityLabel("\(score.percent) percent likely AI-assisted")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(band.title).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Tag(text: "\(score.confidence.rawValue.capitalized) confidence")
                            if !score.isFinal { Tag(text: "Live estimate") }
                            if score.metrics.timingGap { Tag(text: "Audio gap", color: .orange) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !score.reasons.isEmpty {
                    BulletList(title: "Why", items: score.reasons, symbol: "exclamationmark.circle",
                               color: band == .genuine ? .secondary : band.color)
                }
                if !score.counterpoints.isEmpty {
                    BulletList(title: "In their favour", items: score.counterpoints, symbol: "checkmark.circle", color: .green)
                }
                if showsFollowUps && !score.followUps.isEmpty {
                    BulletList(title: "Ask next", items: score.followUps, symbol: "arrow.turn.down.right", color: .accentColor)
                }
                Text("A signal to follow up on, not proof. Ask a follow-up before deciding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

struct BulletList: View {
    let title: String
    let items: [String]
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
            }
        }
    }
}

/// A small rounded label.
struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Silence, stalling, then the answer, on a time axis.
struct TimingStrip: View {
    let model: TimingStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let scale = proxy.size.width / model.duration
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(segment.kind))
                            .frame(width: max(2, CGFloat(min(segment.end, model.duration) - segment.start) * scale))
                            .offset(x: CGFloat(segment.start) * scale)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text(model.summary).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                legend("Silence", .silence)
                legend("Stalling", .stall)
                legend("Answer", .speech)
            }
        }
    }

    private func legend(_ title: String, _ kind: TimingStripModel.Segment.Kind) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(kind)).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ kind: TimingStripModel.Segment.Kind) -> Color {
        switch kind {
        case .silence: return .orange.opacity(0.7)
        case .stall: return .gray.opacity(0.6)
        case .speech: return .accentColor
        }
    }
}

/// One AI answer, streaming in.
struct ReferenceCard: View {
    let answer: ReferenceAnswerRecord
    var isBestMatch = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Tag(text: answer.promptName, color: .accentColor)
                    Spacer(minLength: 0)
                    if answer.isStreaming {
                        ProgressView().controlSize(.small)
                    } else if let first = answer.firstSentenceSeconds, answer.error == nil {
                        Text("first line after \(ScoreNotes.seconds(first))")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("How long a candidate using this tool would wait before they could start reading.")
                    }
                }
                ScrollView {
                    Text(answer.text.isEmpty ? (answer.error == nil ? "Writing\u{2026}" : "No answer") : answer.text)
                        .foregroundStyle(answer.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 190)
                if let error = answer.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(4)
        } label: {
            HStack {
                Text(DetectorModelNames.providerShort(answer.provider, model: answer.model))
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if isBestMatch { Tag(text: "Closest match", color: .red) }
            }
        }
    }
}

/// AI answers side by side, as many columns as fit.
struct ReferenceGrid: View {
    let answers: [ReferenceAnswerRecord]
    var bestMatchLabel: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(answers) { answer in
                ReferenceCard(answer: answer, isBestMatch: bestMatchLabel == answer.label)
            }
        }
    }
}
