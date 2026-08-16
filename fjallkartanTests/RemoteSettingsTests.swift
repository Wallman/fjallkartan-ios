import Foundation
import Testing

@testable import fjallkartan

struct RemoteSettingsTests {
    /// Isolated defaults so tests never touch the real app's suite.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
    }

    private func makeSettings(defaults: UserDefaults) -> RemoteSettings {
        RemoteSettings(defaults: defaults)
    }

    private let remotePayload = """
    {
        "minAppVersion": "1.1",
        "lantmaterietUrl": "https://example.com/se/{z}/{y}/{x}.png",
        "kartverketUrl": "https://example.com/no/{z}/{y}/{x}.png",
        "norwaySlopeUrl": "https://example.com/slope/{z}/{y}/{x}"
    }
    """.data(using: .utf8)!

    @Test func usesBuiltInTemplatesBeforeAnyFetch() {
        let settings = makeSettings(defaults: makeDefaults())

        #expect(settings.minAppVersion == "1.0")
        #expect(settings.tileURL(server: .kartverket, z: 10, x: 2, y: 3).absoluteString
                == "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/10/3/2.png")

        let se = settings.tileURL(server: .lantmateriet, z: 10, x: 2, y: 3).absoluteString
        #expect(se.hasPrefix("https://minkarta.lantmateriet.se/map/topowebbcache?"))
        #expect(se.contains("TileMatrix=10"))
        #expect(se.contains("TileRow=3"))
        #expect(se.contains("TileCol=2"))

        #expect(settings.norwaySlopeTileURL(z: 10, x: 2, y: 3).absoluteString
                == "https://gis3.nve.no/arcgis/rest/services/wmts/Bratthet_med_utlop_2024/MapServer/tile/10/3/2")
    }

    @Test func appliedSettingsReplaceOldSettings() {
        let settings = makeSettings(defaults: makeDefaults())

        #expect(settings.apply(remotePayload))
        #expect(settings.minAppVersion == "1.1")
        #expect(settings.tileURL(server: .kartverket, z: 7, x: 1, y: 2).absoluteString
                == "https://example.com/no/7/2/1.png")
        #expect(settings.tileURL(server: .lantmateriet, z: 7, x: 1, y: 2).absoluteString
                == "https://example.com/se/7/2/1.png")
        #expect(settings.norwaySlopeTileURL(z: 7, x: 1, y: 2).absoluteString
                == "https://example.com/slope/7/2/1")
    }

    @Test func settingsSurviveAFreshInstance() {
        let defaults = makeDefaults()
        #expect(makeSettings(defaults: defaults).apply(remotePayload))

        let relaunched = makeSettings(defaults: defaults)
        #expect(relaunched.tileURL(server: .kartverket, z: 8, x: 4, y: 5).absoluteString
                == "https://example.com/no/8/5/4.png")
        #expect(relaunched.minAppVersion == "1.1")
    }

    @Test(arguments: [
        // Malformed JSON
        "not json at all",
        // Missing a required key
        #"{"minAppVersion": "1.0", "kartverketUrl": "https://example.com/no/{z}/{y}/{x}.png"}"#,
        // Template missing the {x} placeholder
        #"{"lantmaterietUrl": "https://example.com/se/{z}/{y}.png", "kartverketUrl": "https://example.com/no/{z}/{y}/{x}.png"}"#,
        // Template that cannot produce a URL
        #"{"lantmaterietUrl": "https://example.com/se/{z}/{y}/{x}.png", "kartverketUrl": "not a url {z}{x}{y}"}"#,
        // Scheme-less template
        #"{"lantmaterietUrl": "example.com/se/{z}/{y}/{x}.png", "kartverketUrl": "https://example.com/no/{z}/{y}/{x}.png"}"#,
    ])
    func unusablePayloadsKeepPreviousSettings(_ payload: String) {
        let settings = makeSettings(defaults: makeDefaults())
        let before = settings.tileURL(server: .kartverket, z: 9, x: 1, y: 1)

        #expect(settings.apply(Data(payload.utf8)) == false)
        #expect(settings.tileURL(server: .kartverket, z: 9, x: 1, y: 1) == before)
    }

    @Test func persistedUnusableSettingsFallBackToBuiltIn() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: "settings.tiles")

        let settings = makeSettings(defaults: defaults)
        #expect(settings.settings == RemoteSettings.builtIn)
    }

    @Test(arguments: ["1.0", "1.2.3", "0.1", "10.20.30", "1.10"])
    func acceptsDottedNumericVersions(_ version: String) {
        #expect(TileSettings.isWellFormedVersion(version))
    }

    @Test(arguments: ["", "1", "v1.0", "1.0-beta", "1.", ".1", "1..0", "1.0.0.0", "1.o", "１.０"])
    func rejectsMalformedVersions(_ version: String) {
        #expect(TileSettings.isWellFormedVersion(version) == false)
    }
}
