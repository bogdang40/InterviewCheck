import Foundation

struct ProgressiveDesignStep: Identifiable {
    let id: UUID
    let number: Int
    let title: String
    let reasoning: String
    let decision: String
    let tradeOff: String?
    let buildsOn: String?
    let diagramDelta: String?
    let whyNow: String?
    let wasOverriddenDuringMerge: Bool
    let mermaidDiagram: String

    init(
        id: UUID = UUID(),
        number: Int,
        title: String,
        reasoning: String,
        decision: String,
        tradeOff: String? = nil,
        buildsOn: String? = nil,
        diagramDelta: String? = nil,
        whyNow: String? = nil,
        wasOverriddenDuringMerge: Bool = false,
        mermaidDiagram: String
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.reasoning = reasoning
        self.decision = decision
        self.tradeOff = tradeOff
        self.buildsOn = buildsOn
        self.diagramDelta = diagramDelta
        self.whyNow = whyNow
        self.wasOverriddenDuringMerge = wasOverriddenDuringMerge
        self.mermaidDiagram = mermaidDiagram
    }
}

/// Functional and non-functional requirements
struct RequirementsBlock: Identifiable {
    let id = UUID()
    let functional: [String]
    let nonFunctional: [String]
    let assumptions: [String]
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "checklist" }
}

/// High-level architecture with optional Mermaid diagram
struct ArchitectureBlock: Identifiable {
    let id = UUID()
    let description: String
    let mermaidDiagram: String?
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "building.2" }
}

/// Individual component/service in the system
struct ComponentBlock: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let responsibilities: [String]
    let technologies: [String]
    let mermaidDiagram: String?
    
    var icon: String { "cube" }
}

/// Data flow description with sequence diagram
struct DataFlowBlock: Identifiable {
    let id = UUID()
    let description: String
    let mermaidDiagram: String?
    let flows: [DataFlowStep]
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "arrow.triangle.swap" }
}

/// A single step in the data flow
struct DataFlowStep: Identifiable {
    let id = UUID()
    let number: Int
    let from: String
    let to: String
    let description: String
}

/// Database design with ER diagram
struct DatabaseBlock: Identifiable {
    let id = UUID()
    let description: String
    let tables: [DatabaseTable]
    let mermaidDiagram: String?
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "cylinder" }
}

/// A database table schema
struct DatabaseTable: Identifiable {
    let id = UUID()
    let name: String
    let columns: [DatabaseColumn]
    let indexes: [String]
}

/// A column in a database table
struct DatabaseColumn: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let description: String?
}

/// API design with endpoints
struct APIDesignBlock: Identifiable {
    let id = UUID()
    let description: String
    let mermaidDiagram: String?
    let endpoints: [APIEndpoint]
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "network" }
}

/// An API endpoint definition
struct APIEndpoint: Identifiable {
    let id = UUID()
    let method: String          // GET, POST, PUT, DELETE, etc.
    let path: String            // /api/users/{id}
    let description: String
    let requestBody: String?
    let responseBody: String?
}

/// Scalability considerations
struct ScalabilityBlock: Identifiable {
    let id = UUID()
    let description: String
    let mermaidDiagram: String?
    let strategies: [ScalabilityStrategy]
    let bottlenecks: [String]
    let estimations: CapacityEstimation?
    let steps: [ProgressiveDesignStep]
    
    var icon: String { "arrow.up.right.and.arrow.down.left.rectangle" }
}

/// A scalability strategy
struct ScalabilityStrategy: Identifiable {
    let id = UUID()
    let name: String           // "Horizontal Scaling", "Caching", "Sharding", etc.
    let description: String
    let tradeOffs: String?
}

/// Capacity estimation for the system
struct CapacityEstimation: Identifiable {
    let id = UUID()
    let dailyActiveUsers: String?
    let requestsPerSecond: String?
    let storageNeeds: String?
    let bandwidthNeeds: String?
}

/// A trade-off decision made in the design
struct TradeOff: Identifiable {
    let id = UUID()
    let decision: String       // What was chosen
    let alternative: String    // What was rejected
    let reasoning: String      // Why this choice

    var icon: String { "scale.3d" }
}

// MARK: - v2 Taxonomy Blocks

/// One back-of-the-envelope figure: `Metric: value (formula)`.
struct EstimationMetric: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let formula: String?
}

/// The Estimation section: canonical interview capacity math (DAU, QPS,
/// storage, bandwidth, cache sizing) as parseable metric rows plus the
/// usual progressive steps.
struct EstimationBlock {
    let metrics: [EstimationMetric]
    let steps: [ProgressiveDesignStep]

    var icon: String { "number.square" }
}

/// The Wrap-Up section: the complete final architecture plus error
/// scenarios, observability, and the growth path.
struct WrapUpBlock {
    let steps: [ProgressiveDesignStep]

    var icon: String { "flag.checkered" }
}
