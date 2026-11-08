import SwiftUI

/// The parsed detail behind a section: requirement lists, capacity math,
/// components, hops, entities, endpoints, strategies, and trade offs. The
/// stepper already shows a diagram per step, so no block draws its own,
/// and a block with nothing to say renders nothing at all.
struct DesignSectionDetailView: View {
    let section: DesignSection
    let content: SystemDesignContent
    let fontSize: CGFloat

    var body: some View {
        switch section.id {
        case "requirements":
            if let requirements = content.requirements {
                DesignRequirementsBlock(requirements: requirements, fontSize: fontSize)
            }
        case "estimation":
            if let estimation = content.estimation {
                EstimationMetricsView(metrics: estimation.metrics, fontSize: fontSize)
            }
        case "architecture":
            if let architecture = content.architecture {
                DesignProseBlock(text: architecture.description, fontSize: fontSize)
            }
        case "components":
            DesignComponentsBlock(components: content.components, fontSize: fontSize)
        case "dataFlow":
            if let dataFlow = content.dataFlow {
                DesignDataFlowBlock(dataFlow: dataFlow, fontSize: fontSize)
            }
        case "database":
            if let database = content.database {
                DesignDatabaseBlock(database: database, fontSize: fontSize)
            }
        case "apiDesign":
            if let apiDesign = content.apiDesign {
                DesignAPIBlock(apiDesign: apiDesign, fontSize: fontSize)
            }
        case "scalability":
            if let scalability = content.scalability {
                DesignScalabilityBlock(scalability: scalability, fontSize: fontSize)
            }
        case "tradeoffs":
            DesignTradeOffsBlock(tradeOffs: content.tradeOffs, fontSize: fontSize)
        default:
            EmptyView()
        }
    }
}
