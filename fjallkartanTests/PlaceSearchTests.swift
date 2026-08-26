import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

struct PlaceSearchQueryTests {
    @Test @MainActor func reselectingSameResultAdvancesSelectionToken() {
        let model = PlaceSearchModel()
        let result = PlaceResult(
            id: 1,
            name: "Test",
            kind: .settlement,
            matchedAlias: nil,
            municipality: nil,
            region: nil,
            country: .sweden,
            coordinate: CLLocationCoordinate2D(latitude: 67, longitude: 18)
        )

        model.select(result)
        let firstToken = model.selectionToken
        model.select(result)

        #expect(model.selection == result)
        #expect(model.selectionToken == firstToken + 1)
    }

    @Test func buildsPrefixTermsForEachToken() {
        #expect(PlaceSearch.ftsExpression(for: "stora sjöfal") == "stora* AND sjöfal*")
    }

    @Test func singleTokenGetsPrefixOperator() {
        #expect(PlaceSearch.ftsExpression(for: "kebne") == "kebne*")
    }

    @Test(arguments: [
        "sarek\"",
        "sarek*",
        "sarek AND kebne\"",
        "(sarek OR kebne)",
        "sarek^-:",
    ])
    func stripsFtsSyntaxCharacters(input: String) {
        let expression = PlaceSearch.ftsExpression(for: input)
        #expect(expression != nil)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzåäöéèü0123456789* ADN")
        #expect(expression!.allSatisfy { allowed.contains($0) })
        #expect(!expression!.contains("\""))
    }

    @Test(arguments: ["", "   ", "!!!", "-", "()"])
    func returnsNilWhenNothingSearchable(input: String) {
        #expect(PlaceSearch.ftsExpression(for: input) == nil)
    }

    @Test func hyphenatedNameBecomesTwoTerms() {
        #expect(PlaceSearch.ftsExpression(for: "Nord-Odal") == "nord* AND odal*")
    }
}

struct PlaceSearchDatabaseTests {
    private func makeSearch() throws -> PlaceSearch {
        try #require(PlaceSearch(), "places.sqlite missing from the bundle")
    }

    @Test func findsSwedishPeak() throws {
        let results = try makeSearch().search("kebnekaise")
        let first = try #require(results.first)
        #expect(first.name.hasPrefix("Kebnekaise"))
        #expect(first.country == .sweden)
        #expect(abs(first.coordinate.latitude - 67.90) < 0.1)
        #expect(abs(first.coordinate.longitude - 18.44) < 0.1)
    }

    @Test func findsNorwegianPlace() throws {
        let results = try makeSearch().search("galdhøpiggen")
        let first = try #require(results.first)
        #expect(first.country == .norway)
    }

    @Test func asciiQueryMatchesDiacriticName() throws {
        let results = try makeSearch().search("storsjon")
        #expect(results.contains { $0.name.contains("Storsjö") })
    }

    @Test func exactNameOutranksLongerNameWithSamePrefix() throws {
        let results = try makeSearch().search("sarek")
        let first = try #require(results.first)
        #expect(first.name.caseInsensitiveCompare("Sarek") == .orderedSame
                || first.name.caseInsensitiveCompare("Sárek") == .orderedSame)
    }

    @Test func samiAliasResolvesToItsPlace() throws {
        let results = try makeSearch().search("idnetcohkka")
        let first = try #require(results.first)
        #expect(first.matchedAlias != nil)
        #expect(first.name != first.matchedAlias)
    }

    @Test func eachPlaceAppearsOnlyOnce() throws {
        let results = try makeSearch().search("geassenjarga")
        #expect(Set(results.map(\.id)).count == results.count)
    }

    @Test func unknownNameReturnsNothing() throws {
        #expect(try makeSearch().search("qqqzzzxxwv").isEmpty)
    }

    @Test func emptyQueryReturnsNothing() throws {
        #expect(try makeSearch().search("   ").isEmpty)
    }
}

struct PlaceSearchFoldingTests {
    @Test func asciiQueryRanksTheDiacriticNameFirst() throws {
        let search = try #require(PlaceSearch())
        let first = try #require(search.search("storsjo").first)
        // "Norra Storsjön" also matches the term query and carries the same
        // importance, so only the exact-match test keeps it from winning.
        #expect(first.name == "Storsjö", "got \(first.name)")
    }
}

struct PlaceSearchNativeSpellingTests {
    @Test func ligatureMatchesWhenTypedNatively() throws {
        let search = try #require(PlaceSearch())
        let results = search.search("værøy")
        let first = try #require(results.first)
        #expect(first.name.lowercased().hasPrefix("værøy"), "got \(first.name)")
    }
}

struct PlaceSearchImportanceTests {
    @Test func capitalOutranksNearbyCroftsOfTheSameName() throws {
        let search = try #require(PlaceSearch())
        let results = search.search("stockholm")
        let first = try #require(results.first)
        #expect(first.name == "Stockholm")
        #expect(first.municipality == "Stockholm", "got \(first.municipality ?? "nil")")
    }
}

struct PlaceSearchCrossBorderTests {
    @Test func bothCountriesAppearInABorderSearch() throws {
        let search = try #require(PlaceSearch())
        let results = search.search("stor", limit: 60)
        let swedish = results.filter { $0.country == .sweden }
        let norwegian = results.filter { $0.country == .norway }
        #expect(!swedish.isEmpty, "no Swedish hits for a cross-border prefix")
        #expect(!norwegian.isEmpty, "no Norwegian hits for a cross-border prefix")
        // Guards the regression directly: the flat Swedish scale used to sit
        // near the bottom of Norway's, which emptied Sweden out completely.
        #expect(swedish.count >= results.count / 6,
                "Sweden reduced to \(swedish.count) of \(results.count)")
    }
}

struct PlaceSearchLatencyTests {
    @Test(arguments: ["st", "sto", "stor", "va", "fj"])
    func commonPrefixStaysResponsive(_ query: String) throws {
        let search = try #require(PlaceSearch())
        _ = search.search(query)          // warm the cache
        let start = Date()
        let results = search.search(query)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!results.isEmpty)
        #expect(elapsed < 0.5, "'\(query)' took \(Int(elapsed * 1000)) ms")
    }
}
