// swift-tools-version: 5.9
import PackageDescription

/// The detector's core: the shared word clock, question and answer
/// boundaries, and the timing, fluency, similarity and judge signals that
/// make up the score. Pure Swift with no app, UI or network dependencies,
/// so it is fast to test (`swift test`) and reusable by other front ends.
let package = Package(
    name: "InterviewCheckKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "InterviewCheckKit", targets: ["InterviewCheckKit"]),
    ],
    targets: [
        .target(name: "InterviewCheckKit"),
        .testTarget(name: "InterviewCheckKitTests", dependencies: ["InterviewCheckKit"]),
    ]
)
