import Foundation
import Testing
@testable import PushGoAppleCore

struct SearchQuerySemanticsTests {
    @Test
    func indexQueryBuildsTrigramCandidatesAndKeepsExactTokens() throws {
        let query = try #require(SearchQuerySemantics.parse("Claude").indexTextQuery)

        #expect(query.normalizedTokens == ["claude"])
        #expect(query.trigramQuery == "\"cla\" AND \"lau\" AND \"aud\" AND \"ude\"")
    }

    @Test
    func twoCharacterQueryUsesExactSubstringScanWithoutTrigramCandidate() throws {
        let query = try #require(SearchQuerySemantics.parse("Cl").indexTextQuery)

        #expect(query.normalizedTokens == ["cl"])
        #expect(query.trigramQuery == nil)
    }

    @Test
    func indexQueryNormalizesCaseWidthAndDiacritics() throws {
        let query = try #require(SearchQuerySemantics.parse("ＣLÁUDE").indexTextQuery)

        #expect(query.normalizedTokens == ["claude"])
        #expect(query.trigramQuery == "\"cla\" AND \"lau\" AND \"aud\" AND \"ude\"")
    }

    @Test
    func parserPreservesMultiTermAndTagSemantics() throws {
        let parsed = SearchQuerySemantics.parse(" disk\tpressure\n#Critical ")
        let query = try #require(parsed.indexTextQuery)

        #expect(query.normalizedTokens == ["disk", "pressure"])
        #expect(parsed.tags == ["critical"])
    }

    @Test
    func emptyQueryHasNoIndexTextQuery() {
        #expect(SearchQuerySemantics.parse("   ").indexTextQuery == nil)
    }

    @Test
    func thingSearchMatchesPurposeFieldsAndRejectsAnUnrelatedObject() {
        let purposeFields = [
            "Ｐｕｍｐ Café", "Primary coolant pump", "Critical-Asset", "thing-pump-42",
            "archived", "factory-west", "plant-zone", "Bâtiment A / 03",
            "serial SN-8899", #"{"bearing":"SKF-6205","rpm":1450}"#,
            "owner Equipo Málaga",
        ]

        for query in [
            "pump cafe", "coolant", "critical-asset", "pump-42", "archived",
            "factory-west", "plant-zone", "batiment a", "serial", "8899",
            "skf-6205", "malaga",
        ] {
            #expect(SearchQuerySemantics.matchesEntityFields(purposeFields, rawQuery: query))
        }
        #expect(!SearchQuerySemantics.matchesEntityFields(purposeFields, rawQuery: "missing turbine"))
        #expect(SearchQuerySemantics.matchesEntityFields(purposeFields, rawQuery: "  "))
    }
}
