import SwiftUI

/// Deterministic scene shared by live playback and native render fixtures.
struct AbleyWelcomeScene: View {
    let elapsed: TimeInterval
    let image: CGImage?
    var reduceMotion = false
    var borderWidth: CGFloat = 0
    let onSkip: () -> Void

    private let forest = Color(red: 0.13, green: 0.20, blue: 0.15)
    private let porcelain = Color(red: 0.97, green: 0.94, blue: 0.87)

    var body: some View {
        GeometryReader { geometry in
            let motion = AbleyWelcomeMotion(elapsed: elapsed, size: geometry.size,
                                            reduceMotion: reduceMotion, borderWidth: borderWidth)
            ZStack(alignment: .topTrailing) {
                forest.opacity(motion.backdropOpacity)
                Text("Hello!")
                    .font(.system(size: min(62, max(38, geometry.size.width * 0.09)), weight: .semibold, design: .rounded))
                    .foregroundStyle(porcelain)
                    .position(x: geometry.size.width / 2, y: max(72, geometry.size.height * 0.13))
                    .opacity(motion.greetingOpacity)
                    .accessibilityLabel("Abley says hello")

                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high).scaledToFit()
                            .opacity(1 - motion.iconOpacity)
                    }
                    Image("AbleyLogo")
                        .resizable().scaledToFit()
                        .opacity(image == nil ? 1 : motion.iconOpacity)
                }
                .frame(width: motion.characterSize, height: motion.characterSize)
                .position(motion.center)
                .accessibilityHidden(true)

                Button("Skip", action: onSkip)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(porcelain)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(forest.opacity(0.85), in: Capsule())
                    .overlay(Capsule().stroke(porcelain.opacity(0.35), lineWidth: 1))
                    .buttonStyle(.plain)
                    .padding(16)
                    .opacity(elapsed < 3.65 || reduceMotion ? 1 : 0)
                    .allowsHitTesting(elapsed < 3.65 || reduceMotion)
                    .accessibilityIdentifier("abley.welcome.skip")
            }
            .contentShape(Rectangle())
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("abley.welcome")
    }
}

struct AbleyWelcomeAnimation: View {
    var borderWidth: CGFloat = 0
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var playback = AbleyWelcomePlayback()

    var body: some View {
        AbleyWelcomeScene(elapsed: playback.elapsed, image: playback.image,
                          reduceMotion: playback.usesStillGreeting, borderWidth: borderWidth, onSkip: onFinish)
            .task(id: reduceMotion) {
                await playback.play(reduceMotion: reduceMotion, completion: onFinish)
            }
    }
}
