import Foundation

/// One memoized cache per section parser: the single choke point through
/// which the MentorResponse parsed* accessors and the Quick Assist section
/// view obtain parse products.
///
/// SectionParser's static methods stay un-memoized: golden tests call them
/// directly and always see the raw parser, byte for byte.
enum SectionParseStore {
    static let problem = MemoizedParse<ProblemContent>()
    static let questions = MemoizedParse<QuestionsContent>()
    static let implementation = MemoizedParse<ImplementationContent>()
    static let tests = MemoizedParse<TestsContent>()
    static let complexity = MemoizedParse<ComplexityContent>()
    static let systemDesign = MemoizedParse<SystemDesignContent>()
    static let quickAssistSections = MemoizedParse<[QuickAssistSectionModel]>()
}
