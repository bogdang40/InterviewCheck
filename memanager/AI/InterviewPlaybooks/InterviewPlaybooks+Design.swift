import Foundation

/// Long form design families answered inside Quick Assist. The full solve
/// surface keeps its own SystemDesignBlueprint pipeline; these playbooks
/// shape the spoken, interviewer facing version of the same thinking.
enum InterviewDesignPlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "system_design",
            displayName: "System design",
            frameworkName: "Leveled Design Loop",
            frameworkSummary: "Requirements that shape everything, rounded capacity math, the core architecture, one deep dive where the hard problem lives, defended tradeoffs, and the ten times growth story.",
            strongCues: [
                "design a system",
                "how would you scale",
                "architecture for",
                "design twitter",
                "design a url shortener",
                "system design"
            ],
            cues: [
                "how would you design", "design a service",
                "throughput", "latency", "partition", "load balancer",
                "replication", "availability", "sharding", "consistency"
            ],
            beats: [
                "Requirements: the two functional and two nonfunctional requirements that shape everything.",
                "Scale: the rough numbers that matter, computed aloud with rounded math.",
                "Architecture: the core components and the request path between them.",
                "Deep dive: the one component where the hard problem actually lives.",
                "Tradeoffs: the choice I would defend and the alternative I rejected.",
                "Evolution: what breaks first at ten times the load and how I would fix it."
            ],
            spokenLengthTarget: "paced to the round, requirements in under 5 minutes",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: true,
            legacyIntent: .systemDesign,
            depth: .architectureDeep
        ),
        InterviewAnswerPlaybook(
            id: "api_object_design",
            displayName: "API and object design",
            frameworkName: "Use Case First",
            frameworkSummary: "Concrete caller use cases first, then entities, then interfaces with error semantics, then how the design absorbs the next requirement.",
            strongCues: [
                "design a parking lot",
                "design a class",
                "object oriented design",
                "design the api",
                "low level design",
                "design an elevator"
            ],
            cues: ["interface design", "class diagram", "design patterns", "extensible design"],
            beats: [
                "Use cases: the concrete operations callers actually need.",
                "Entities: the core types and the relationships between them.",
                "Interface: signatures or endpoints with explicit error semantics.",
                "Evolution: how the design absorbs the next requirement without breaking."
            ],
            spokenLengthTarget: "paced to the round, use cases in the first 3 minutes",
            voiceStyle: .technical,
            allowsCode: true,
            allowsMermaid: true,
            legacyIntent: .systemDesign,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "ml_system_design",
            displayName: "ML system design",
            frameworkName: "Framing Loop",
            frameworkSummary: "Business metric translated into the ML objective, data and labels with their failure modes, baseline before model, offline and online evaluation, serving, and drift monitoring.",
            strongCues: [
                "recommendation system",
                "fraud detection system",
                "search ranking",
                "design an ml system",
                "machine learning system",
                "end to end ml"
            ],
            cues: ["recommendation", "fraud", "personalization", "feature store", "model serving", "training pipeline", "ranking model", "embeddings"],
            beats: [
                "Framing: the business metric translated into the ML objective.",
                "Data: sources, labels, and their failure modes.",
                "Model: the baseline first, then the model that earns its complexity.",
                "Evaluation: the offline metric, the online metric, and the gap between them.",
                "Serving: latency, freshness, and rollout strategy.",
                "Monitoring: drift, feedback loops, and retraining triggers."
            ],
            spokenLengthTarget: "paced to the round, framing in the first 5 minutes",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: true,
            legacyIntent: .systemDesign,
            depth: .architectureDeep
        ),
        InterviewAnswerPlaybook(
            id: "incident_response",
            displayName: "Incident response",
            frameworkName: "Mitigate First",
            frameworkSummary: "Assess severity, stabilize before root causing, communicate clearly, diagnose starting from recent changes, then verify recovery and run the blameless loop.",
            strongCues: [
                "you get paged",
                "production is down",
                "latency spiked",
                "site is down",
                "walk me through an incident",
                "on call and"
            ],
            cues: ["sev1", "outage", "rollback", "postmortem", "error rate jumped"],
            beats: [
                "Severity: blast radius and user impact assessed first.",
                "Stabilize: mitigate before root cause, rollback beats live debugging.",
                "Communicate: who I tell, what I tell them, and when.",
                "Diagnose: recent changes first, then the metrics trail.",
                "Verify and learn: prove recovery, then the blameless postmortem."
            ],
            spokenLengthTarget: "3 to 5 minutes per scenario",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .debug,
            depth: .structuredDeep
        )
    ]
}
