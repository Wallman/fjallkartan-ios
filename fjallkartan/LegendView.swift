import SwiftUI

enum LegendCountry: String, CaseIterable, Identifiable {
    case sweden
    case norway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .norway: String(localized: "Norway")
        case .sweden: String(localized: "Sweden")
        }
    }

    var sections: [LegendSection] {
        switch self {
        case .norway: LegendCatalog.norway
        case .sweden: LegendCatalog.sweden
        }
    }
}

/// One legend row: a symbol drawn exactly as the map draws it, the translated
/// name, and the official name from the mapping agency's own specification.
struct LegendEntry: Identifiable {
    let asset: String
    let title: LocalizedStringResource
    let nativeName: String

    var id: String { asset }

    /// Symbols wider than they are tall are lines and need a wide chip; point
    /// symbols get a square one so they are not stretched across it.
    var isLine: Bool { LegendCatalog.lineAssets.contains(asset) }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return String(localized: title).localizedCaseInsensitiveContains(needle)
            || nativeName.localizedCaseInsensitiveContains(needle)
    }
}

struct LegendSection: Identifiable {
    let title: LocalizedStringResource
    let entries: [LegendEntry]

    var id: String { entries.first?.asset ?? String(localized: title) }
}

struct LegendSheet: View {
    @State private var country: LegendCountry = .sweden
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var sections: [LegendSection] {
        country.sections.compactMap { section in
            let entries = section.entries.filter { $0.matches(query) }
            return entries.isEmpty ? nil : LegendSection(title: section.title, entries: entries)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(String(localized: section.title)) {
                        ForEach(section.entries) { entry in
                            LegendRow(entry: entry)
                        }
                    }
                }

                if query.isEmpty {
                    SlopeLegendSection(country: country)
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: Text("Find a symbol"))
            .navigationTitle("Legend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Country", selection: $country) {
                        ForEach(LegendCountry.allCases) { country in
                            Text(country.title).tag(country)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct LegendRow: View {
    let entry: LegendEntry

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LegendRowLayout(isStacked: typeSize.isAccessibilitySize) {
            LegendChip(asset: entry.asset, isLine: entry.isLine)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.nativeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: entry.title)), \(entry.nativeName)"))
    }
}

/// At accessibility text sizes the label needs the full width, so the symbol
/// moves above it instead of competing for the same line.
private struct LegendRowLayout<Content: View>: View {
    let isStacked: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: 8) { content }
        } else {
            HStack(spacing: 14) { content }
        }
    }
}

/// The symbol on a light "map paper" background regardless of colour scheme.
/// The symbols are coloured for a light basemap -- a near-white tractor road or
/// a white-backed hut would vanish entirely on a dark row.
private struct LegendChip: View {
    let asset: String
    let isLine: Bool

    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 38

    /// Scaled with the text so it stays proportionate, but capped: past this the
    /// symbol is already unambiguous and only steals width from the label.
    private var height: CGFloat { min(unit, 60) }
    private var width: CGFloat { isLine ? height * 1.7 : height }

    var body: some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(3)
            .frame(width: width, height: height)
            .background(LegendChip.paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    /// The paper tone both agencies print their topographic maps on.
    static let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
}

/// The steepness overlay has no printed legend to convert -- these are the class
/// breaks and colours `tools/build_sweden_slope_tiles.py` renders, which match
/// NVE's scale so the two countries meet seamlessly at the border.
private struct SlopeLegendSection: View {
    let country: LegendCountry

    private struct Band: Identifiable {
        let colour: Color
        let label: LocalizedStringResource
        var id: String { String(localized: label) }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static let bands: [Band] = [
        Band(colour: rgb(255, 255, 0), label: "30–35°"),
        Band(colour: rgb(255, 170, 0), label: "35–40°"),
        Band(colour: rgb(255, 85, 0), label: "40–45°"),
        Band(colour: rgb(255, 0, 0), label: "45–50°"),
        Band(colour: rgb(115, 0, 0), label: "50° and steeper"),
    ]

    var body: some View {
        Section {
            ForEach(Self.bands) { band in
                SlopeRow(colour: band.colour, label: Text(band.label))
            }
            if country == .norway {
                SlopeRow(
                    colour: Self.rgb(76, 155, 255),
                    label: Text("Modelled avalanche runout")
                )
            }
        } header: {
            Text("Steepness")
        }
    }
}

private struct SlopeRow: View {
    let colour: Color
    let label: Text

    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 38
    @Environment(\.dynamicTypeSize) private var typeSize

    private var height: CGFloat { min(unit, 60) }

    var body: some View {
        LegendRowLayout(isStacked: typeSize.isAccessibilitySize) {
            RoundedRectangle(cornerRadius: 6)
                .fill(colour)
                .frame(width: height * 1.7, height: height)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            label
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    LegendSheet()
}
