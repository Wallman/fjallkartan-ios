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

    var sourceMaximumZ: Int {
        switch country {
        case .norway: return 16
        case .sweden: return 13
        }
    }

    init(country: Country) {
        self.country = country
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 5
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

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let z = Int(path.z)
        guard z > sourceMaximumZ else {
            super.loadTile(at: path, result: result)
            return
        }

        let levels = z - sourceMaximumZ
        var ancestor = path
        ancestor.z = sourceMaximumZ
        ancestor.x = path.x >> levels
        ancestor.y = path.y >> levels

        super.loadTile(at: ancestor) { data, error in
            guard let data else {
                result(nil, error)
                return
            }
            let scaled = TileUpscaler.upscaledTile(
                ancestor: (z: self.sourceMaximumZ,
                           x: Int(ancestor.x),
                           y: Int(ancestor.y),
                           data: data),
                targetZ: z, targetX: Int(path.x), targetY: Int(path.y),
                interpolation: .none
            )
            result(scaled, scaled == nil ? error : nil)
        }
    }
}
