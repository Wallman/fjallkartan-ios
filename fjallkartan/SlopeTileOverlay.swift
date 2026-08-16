import MapKit

final class SlopeTileOverlay: MKTileOverlay {
    enum Country {
        case norway, sweden
    }

    let country: Country

    static func norway() -> SlopeTileOverlay {
        SlopeTileOverlay(country: .norway)
    }

    static func sweden() -> SlopeTileOverlay {
        SlopeTileOverlay(country: .sweden)
    }

    init(country: Country) {
        self.country = country
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        switch country {
        case .norway:
            minimumZ = 5
            maximumZ = 16
        case .sweden:
            minimumZ = 5
            maximumZ = 13
        }
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let z = Int(path.z), x = Int(path.x), y = Int(path.y)
        switch country {
        case .norway:
            return RemoteSettings.shared.norwaySlopeTileURL(z: z, x: x, y: y)
        case .sweden:
            return RemoteSettings.shared.swedenSlopeTileURL(z: z, x: x, y: y)
        }
    }
}
