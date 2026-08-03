import CoreImage
import CoreLocation
import MapKit
import UIKit

/// Needed because MapKit only draws a heading cone while the map is in `.followWithHeading`,
/// which also recentres and rotates the camera on every update.
final class UserLocationAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "UserLocation"

    private static let dotDiameter: CGFloat = 22
    private static let ringWidth: CGFloat = 3
    private static let coneRadius: CGFloat = 52
    private static let coneHalfAngle: CGFloat = .pi / 6

    var heading: CLLocationDirection? {
        didSet { applyRotation() }
    }

    var mapHeading: CLLocationDirection = 0 {
        didSet { applyRotation() }
    }

    private let coneView = UIImageView()
    private let dotView = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        let side = Self.coneRadius * 2
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        isUserInteractionEnabled = false
        canShowCallout = false
        zPriority = .max
        collisionMode = .circle

        coneView.frame = bounds
        coneView.image = Self.coneImage
        coneView.isHidden = true
        addSubview(coneView)

        dotView.frame = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dotView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dotView.backgroundColor = .systemBlue
        dotView.layer.cornerRadius = Self.dotDiameter / 2
        dotView.layer.borderWidth = Self.ringWidth
        dotView.layer.borderColor = UIColor.white.cgColor
        dotView.layer.shadowColor = UIColor.black.cgColor
        dotView.layer.shadowOpacity = 0.3
        dotView.layer.shadowRadius = 3
        dotView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dotView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        heading = nil
        mapHeading = 0
    }

    private func applyRotation() {
        guard let heading else {
            coneView.isHidden = true
            return
        }
        coneView.isHidden = false
        coneView.transform = CGAffineTransform(rotationAngle: CGFloat((heading - mapHeading) * .pi / 180))
    }

    // MARK: - Cone image

    private static let coneImage: UIImage = {
        let side = coneRadius * 2
        let center = CGPoint(x: coneRadius, y: coneRadius)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))

        let wedge = renderer.image { context in
            let cgContext = context.cgContext
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center,
                        radius: coneRadius,
                        startAngle: -.pi / 2 - coneHalfAngle,
                        endAngle: -.pi / 2 + coneHalfAngle,
                        clockwise: true)
            path.close()

            cgContext.addPath(path.cgPath)
            cgContext.clip()

            let colors = [UIColor.systemBlue.withAlphaComponent(0.55).cgColor,
                          UIColor.systemBlue.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors,
                                            locations: [0, 1]) else { return }
            cgContext.drawRadialGradient(gradient,
                                         startCenter: center,
                                         startRadius: dotDiameter / 2,
                                         endCenter: center,
                                         endRadius: coneRadius,
                                         options: [])
        }

        return softened(wedge) ?? wedge
    }()

    private static func softened(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIGaussianBlur",
                                    parameters: [kCIInputImageKey: input.clampedToExtent(),
                                                 kCIInputRadiusKey: 3.0]),
              let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: input.extent)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }
}
