import SwiftUI

/// A hint shown once, the first time a mode is actually used.
enum GuideTip: String, CaseIterable, Identifiable {
    case measuringGestures = "guide.tip.measuringGestures"
    case elevationReadout = "guide.tip.elevationReadout"
    case regionPreview = "guide.tip.regionPreview"
    case routeSaved = "guide.tip.routeSaved"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .measuringGestures: "hand.draw"
        case .elevationReadout: "mountain.2"
        case .regionPreview: "dot.squareshape.split.2x2"
        case .routeSaved: "bookmark.fill"
        }
    }

    var text: LocalizedStringResource {
        switch self {
        case .measuringGestures: "One finger draws. Two fingers move the map."
        case .elevationReadout: "Tap the distance to see the elevation profile."
        case .regionPreview: "The dashed box is what gets downloaded."
        case .routeSaved: "Saved routes are under the bookmark button."
        }
    }

    var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: rawValue)
    }

    func markSeen() {
        UserDefaults.standard.set(true, forKey: rawValue)
    }
}

struct GuideTipBadge: View {
    let tip: GuideTip
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tip.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(tip.text)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    GuideTipBadge(tip: .measuringGestures) {}
}
