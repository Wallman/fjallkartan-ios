import Charts
import SwiftUI

/// Terrain profile of the measured route, opened from the distance readout.
struct ElevationProfileSheet: View {
    let profile: ElevationProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if profile.hasData {
                    chart
                } else {
                    ContentUnavailableView(
                        "No elevation data",
                        systemImage: "mountain.2",
                        description: Text("This route is outside the covered area.")
                    )
                }
            }
            .navigationTitle("Elevation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("elevationProfile.done")
                }
            }
        }
        .accessibilityIdentifier("elevationProfile.sheet")
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary

            Chart {
                // Only points with data are plotted, so a stretch the tiles
                // could not answer shows as a break rather than a drop to zero.
                ForEach(Array(profile.points.enumerated()), id: \.offset) { _, point in
                    if let elevation = point.elevation {
                        AreaMark(
                            x: .value("Distance", point.distance / 1000),
                            y: .value("Elevation", elevation)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [.orange.opacity(0.45), .orange.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    }
                }
                ForEach(Array(profile.points.enumerated()), id: \.offset) { _, point in
                    if let elevation = point.elevation {
                        LineMark(
                            x: .value("Distance", point.distance / 1000),
                            y: .value("Elevation", elevation)
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel("km")
            .chartYAxisLabel("m")
            .frame(minHeight: 220)
            .accessibilityIdentifier("elevationProfile.chart")

            if profile.isPartial {
                Label("Part of this route is outside the covered area, so the totals are a minimum.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var summary: some View {
        HStack(spacing: 20) {
            stat("Ascent", profile.formattedAscent, "arrow.up")
            stat("Descent", profile.formattedDescent, "arrow.down")
            if let maximum = profile.maximum {
                stat("Highest", ElevationProfile.formatted(meters: maximum), "mountain.2")
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    /// Padded so a flat route does not render as a single line filling the plot.
    private var yDomain: ClosedRange<Double> {
        guard let low = profile.minimum, let high = profile.maximum else { return 0...100 }
        let padding = max((high - low) * 0.15, 10)
        return (low - padding)...(high + padding)
    }
}
