// swift-tools-version: 5.9
import PackageDescription

/// Connectors to the systems interviews live in: applicant tracking systems
/// (directly and through unified APIs), calendars, mail and meeting
/// platforms, and MCP servers. Each connector turns its system's API into
/// the same few types (upcoming interviews, candidates, jobs, recordings).
/// No UI and no app dependencies; every connector is tested against
/// recorded responses through a stub transport (`swift test`).
let package = Package(
    name: "InterviewCheckConnectors",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InterviewCheckConnectors", targets: ["InterviewCheckConnectors"]),
    ],
    targets: [
        .target(name: "InterviewCheckConnectors"),
        .testTarget(name: "InterviewCheckConnectorsTests", dependencies: ["InterviewCheckConnectors"]),
    ]
)
