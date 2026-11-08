import SwiftUI
import InterviewCheckKit

/// Colours with one meaning each: score bands are green, orange and red;
/// words matched to an AI answer get the marker; live activity is blue.
enum Palette {
    /// Highlighter yellow, read with black text in light and dark mode.
    static let marker = Color(red: 1.0, green: 0.86, blue: 0.35)
    static let live = Color.blue
}

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
    /// How this answer differs from the candidate's other answers, if it does.
    var baselineNote: String?

    private var band: ScoreBand { ScoreBand(percent: score.percent) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(score.percent)%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(band.color)
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
                // One spoken summary instead of five separate pieces.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                if !score.reasons.isEmpty {
                    BulletList(title: "Why", items: score.reasons, symbol: "exclamationmark.circle",
                               color: band == .genuine ? .secondary : band.color)
                }
                if let baselineNote {
                    BulletList(title: "Compared with their other answers", items: [baselineNote],
                               symbol: "person.crop.circle.badge.exclamationmark", color: .orange)
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

    private var accessibilitySummary: String {
        var parts = ["\(score.percent) percent", band.title, "\(score.confidence.rawValue) confidence"]
        if !score.isFinal { parts.append("live estimate") }
        if score.metrics.timingGap { parts.append("audio gap") }
        return parts.joined(separator: ", ")
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
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                }
            }
        }
    }
}

/// A small label in the marker colour, for words matched to an AI answer.
struct MarkerTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.marker))
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

/// Silence, stalling, then the answer, on a time axis, with a tick where
/// the fastest AI answer had its first line.
struct TimingStrip: View {
    let model: TimingStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let scale = proxy.size.width / model.duration
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 10)
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(segment.kind))
                            .frame(width: max(2, CGFloat(min(segment.end, model.duration) - segment.start) * scale), height: 10)
                            .offset(x: CGFloat(segment.start) * scale)
                    }
                    if let ai = model.aiFirstLine {
                        Capsule().fill(Color.primary.opacity(0.85))
                            .frame(width: 3, height: 20)
                            .offset(x: max(0, CGFloat(ai) * scale - 1.5))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text(model.summary).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Group {
                    legend("Silence", .silence)
                    legend("Stalling", .stall)
                    legend("Answer", .speech)
                    if model.aiFirstLine != nil {
                        HStack(spacing: 4) {
                            Capsule().fill(Color.primary.opacity(0.85)).frame(width: 2.5, height: 10)
                            Text("AI's first line").font(.caption).foregroundStyle(.secondary)
                        }
                        .help("When the fastest AI answer had its first line: the earliest a candidate reading from a tool could start.")
                    }
                }
                .accessibilityHidden(true)
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
        case .silence: return Color.secondary.opacity(0.75)
        case .stall: return Color.secondary.opacity(0.3)
        case .speech: return Palette.live.opacity(0.75)
        }
    }
}

/// A small all-caps section label that VoiceOver reads as a heading in
/// normal case.
struct SectionCaption: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}
