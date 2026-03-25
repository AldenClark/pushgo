import Foundation
import Testing
@testable import PushGoAppleCore

struct SearchQuerySemanticsTests {
    @Test
    func normalizedQueryQuotesWhitespaceSeparatedTerms() {
        #expect(
            SearchQuerySemantics.normalizedSearchIndexQuery(from: " cpu   warning ") ==
            "\"cpu\" AND \"warning\""
        )
    }

    @Test
    func normalizedQueryStripsEmbeddedQuotes() {
        #expect(
            SearchQuerySemantics.normalizedSearchIndexQuery(from: "\"quoted\" alert") ==
            "\"quoted\" AND \"alert\""
        )
    }

    @Test
    func normalizedQueryTreatsMixedWhitespaceAsSeparators() {
        #expect(
            SearchQuerySemantics.normalizedSearchIndexQuery(from: "disk\tpressure\ncritical") ==
            "\"disk\" AND \"pressure\" AND \"critical\""
        )
    }

    @Test
    func emptyQueryReturnsOriginalInput() {
        #expect(SearchQuerySemantics.normalizedSearchIndexQuery(from: "   ") == "   ")
    }
}
