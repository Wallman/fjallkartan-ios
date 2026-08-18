import Foundation
import Testing

@testable import fjallkartan

/// The captions under the map buttons are content, not logic: a missing
/// catalog entry silently falls back to the English key, which only shows up
/// when someone runs the app in another language.
@MainActor
struct MapControlLabelTests {
    @Test func everyLabelIsInTheCatalog() {
        let swedish = Locale(identifier: "sv")
        for resource in MapControlLabel.all {
            var localized = resource
            localized.locale = swedish
            #expect(String(localized: localized) != resource.key,
                    "untranslated map control label: \(resource.key)")
        }
    }

    /// A caption wider than its button pushes the column off the map edge, so
    /// keep them short enough that the fixed label width can hold them.
    @Test func everyLabelIsShort() {
        for language in ["en", "da", "de", "es", "fi", "fr", "it", "nb", "nl", "sv", "zh-Hans"] {
            for resource in MapControlLabel.all {
                var localized = resource
                localized.locale = Locale(identifier: language)
                let value = String(localized: localized)
                #expect(value.count <= 12,
                        "map control label too long in \(language): \(value)")
            }
        }
    }
}
