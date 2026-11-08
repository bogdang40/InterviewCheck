import Foundation

// MARK: - Section Parser

/// Facade over the section parsers in Models/Parsing.
/// Every method keeps its original signature and delegates verbatim.
struct SectionParser {
    /// Extracts [-> code:label] link from text
    static func parseCodeLink(from text: String) -> String? {
        ImplementationSectionParser.parseCodeLink(from: text)
    }

    static func parseProblem(_ text: String) -> ProblemContent {
        ProblemSectionParser.parseProblem(text)
    }

    static func parseQuestions(_ text: String) -> QuestionsContent {
        QuestionsSectionParser.parseQuestions(text)
    }

    static func parseImplementation(_ text: String) -> ImplementationContent {
        ImplementationSectionParser.parseImplementation(text)
    }

    static func parseTests(_ text: String) -> TestsContent {
        TestsSectionParser.parseTests(text)
    }

    static func parseComplexity(_ text: String) -> ComplexityContent {
        ComplexitySectionParser.parseComplexity(text)
    }

    static func parseSystemDesign(_ text: String) -> SystemDesignContent {
        SystemDesignSectionParser.parseSystemDesign(text)
    }
}

// MARK: - MentorResponse Extension

/// Memoized through SectionParseStore: these accessors are read from view
/// bodies on every publish, and re-parsing regenerated every product's UUID
/// identity, defeating SwiftUI diffing. Unchanged input now returns the same
/// cached instance; parse OUTPUT is unchanged by construction.
extension MentorResponse {
    var parsedProblem: ProblemContent {
        SectionParseStore.problem.value(for: problem, compute: SectionParser.parseProblem)
    }

    var parsedQuestions: QuestionsContent {
        SectionParseStore.questions.value(for: clarifyingQuestions, compute: SectionParser.parseQuestions)
    }

    var parsedImplementation: ImplementationContent {
        SectionParseStore.implementation.value(for: implementation, compute: SectionParser.parseImplementation)
    }

    var parsedTests: TestsContent {
        SectionParseStore.tests.value(for: tests, compute: SectionParser.parseTests)
    }

    var parsedComplexity: ComplexityContent {
        SectionParseStore.complexity.value(for: complexity, compute: SectionParser.parseComplexity)
    }

    var parsedSystemDesign: SystemDesignContent {
        SectionParseStore.systemDesign.value(for: systemDesign, compute: SectionParser.parseSystemDesign)
    }
}
