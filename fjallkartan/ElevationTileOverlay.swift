import MapKit

final class ElevationTileOverlay: MKTileOverlay {
    static func norway() -> ElevationTileOverlay {
        ElevationTileOverlay()
    }

    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        maximumZ = 16
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        RemoteSettings.shared.norwayElevationTileURL(z: Int(path.z), x: Int(path.x), y: Int(path.y))
    }
}
