import Foundation

struct SystemDesignContent {
    let requirements: RequirementsBlock?
    let architecture: ArchitectureBlock?
    let components: [ComponentBlock]
    let componentSteps: [ProgressiveDesignStep]
    let dataFlow: DataFlowBlock?
    let database: DatabaseBlock?
    let apiDesign: APIDesignBlock?
    let scalability: ScalabilityBlock?
    let tradeOffs: [TradeOff]
    let tradeOffSteps: [ProgressiveDesignStep]
    let rawContent: String
    /// v2 taxonomy sections; vars with defaults so existing construction
    /// sites and fixtures compile unchanged.
    var estimation: EstimationBlock?
    var wrapUp: WrapUpBlock?

    init(
        requirements: RequirementsBlock?,
        architecture: ArchitectureBlock?,
        components: [ComponentBlock],
        componentSteps: [ProgressiveDesignStep],
        dataFlow: DataFlowBlock?,
        database: DatabaseBlock?,
        apiDesign: APIDesignBlock?,
        scalability: ScalabilityBlock?,
        tradeOffs: [TradeOff],
        tradeOffSteps: [ProgressiveDesignStep],
        rawContent: String,
        estimation: EstimationBlock? = nil,
        wrapUp: WrapUpBlock? = nil
    ) {
        self.requirements = requirements
        self.architecture = architecture
        self.components = components
        self.componentSteps = componentSteps
        self.dataFlow = dataFlow
        self.database = database
        self.apiDesign = apiDesign
        self.scalability = scalability
        self.tradeOffs = tradeOffs
        self.tradeOffSteps = tradeOffSteps
        self.rawContent = rawContent
        self.estimation = estimation
        self.wrapUp = wrapUp
    }
    
    var isEmpty: Bool {
        requirements == nil && architecture == nil && components.isEmpty &&
        componentSteps.isEmpty &&
        dataFlow == nil && database == nil && apiDesign == nil &&
        scalability == nil && tradeOffs.isEmpty && tradeOffSteps.isEmpty &&
        rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var hasStructuredContent: Bool {
        requirements != nil || architecture != nil || !components.isEmpty ||
        !componentSteps.isEmpty ||
        dataFlow != nil || database != nil || apiDesign != nil ||
        scalability != nil || !tradeOffs.isEmpty || !tradeOffSteps.isEmpty ||
        estimation != nil || wrapUp != nil
    }
    
    var hasContent: Bool {
        hasStructuredContent || !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasProgressiveContent: Bool {
        (requirements?.steps.isEmpty == false) ||
        (estimation?.steps.isEmpty == false) ||
        (architecture?.steps.isEmpty == false) ||
        !componentSteps.isEmpty ||
        (dataFlow?.steps.isEmpty == false) ||
        (database?.steps.isEmpty == false) ||
        (apiDesign?.steps.isEmpty == false) ||
        (scalability?.steps.isEmpty == false) ||
        !tradeOffSteps.isEmpty ||
        (wrapUp?.steps.isEmpty == false)
    }

    func progressiveStepCount(for sectionID: String) -> Int {
        progressiveSteps(for: sectionID).count
    }

    func progressiveSteps(for sectionID: String) -> [ProgressiveDesignStep] {
        switch sectionID {
        case "requirements":
            return requirements?.steps ?? []
        case "estimation":
            return estimation?.steps ?? []
        case "wrapUp":
            return wrapUp?.steps ?? []
        case "architecture":
            return architecture?.steps ?? []
        case "components":
            return componentSteps
        case "dataFlow":
            return dataFlow?.steps ?? []
        case "database":
            return database?.steps ?? []
        case "apiDesign":
            return apiDesign?.steps ?? []
        case "scalability":
            return scalability?.steps ?? []
        case "tradeoffs":
            return tradeOffSteps
        default:
            return []
        }
    }
}
