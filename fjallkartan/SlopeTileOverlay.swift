import MapKit

final class SlopeTileOverlay: MKTileOverlay {
    static func norway() -> SlopeTileOverlay {
        SlopeTileOverlay()
    }

    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        maximumZ = 16
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        RemoteSettings.shared.norwaySlopeTileURL(z: Int(path.z), x: Int(path.x), y: Int(path.y))
    }
}
