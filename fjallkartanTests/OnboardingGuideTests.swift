import Foundation
import Testing
import UIKit

@testable import fjallkartan

/// The guide is content, not logic, so what is worth guarding is the
/// inventory: every symbol has to exist and every string has to be in the
/// catalog, both of which fail silently at runtime.
@MainActor
struct OnboardingGuideTests {
    private var allResources: [LocalizedStringResource] {
        OnboardingPage.all.flatMap { [$0.title, $0.message] + $0.notes.map(\.text) }
            + GuideTip.allCases.map(\.text)
    }

    private var allSymbols: [String] {
        OnboardingPage.all.flatMap { [$0.symbol] + $0.notes.map(\.symbol) }
            + GuideTip.allCases.map(\.symbol)
    }

    @Test func pagesAreUniquelyIdentified() {
        let ids = OnboardingPage.all.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    /// A misspelled SF Symbol renders as nothing at all, which is invisible in
    /// a screenshot review but obvious here.
    @Test func everySymbolExists() {
        for symbol in allSymbols {
            #expect(UIImage(systemName: symbol) != nil, "missing SF Symbol: \(symbol)")
        }
    }

    /// `String(localized:)` falls back to the key itself when the catalog has
    /// no entry, so a translated value that differs from the key proves the
    /// string was actually extracted.
    @Test func everyStringIsInTheCatalog() {
        let swedish = Locale(identifier: "sv")
        for resource in allResources {
            var localized = resource
            localized.locale = swedish
            #expect(String(localized: localized) != resource.key,
                    "untranslated guide string: \(resource.key)")
        }
    }

    @Test func everyTipHasItsOwnDefaultsKey() {
        let keys = GuideTip.allCases.map(\.rawValue)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("guide.tip.") })
    }

    @Test func tipIsOnlyShownOnce() {
        let defaults = UserDefaults.standard
        let tip = GuideTip.measuringGestures
        let original = defaults.object(forKey: tip.rawValue)
        defer {
            if let original { defaults.set(original, forKey: tip.rawValue) }
            else { defaults.removeObject(forKey: tip.rawValue) }
        }

        defaults.removeObject(forKey: tip.rawValue)
        #expect(!tip.hasBeenSeen)
        tip.markSeen()
        #expect(tip.hasBeenSeen)
    }
}
