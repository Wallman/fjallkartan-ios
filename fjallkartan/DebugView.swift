import SwiftUI

struct DebugSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let metrics: TileMetrics
    @State private var snapshot: TileMetrics.Snapshot
    @State private var isConfirmingReset = false

    init(metrics: TileMetrics = .shared) {
        self.metrics = metrics
        _snapshot = State(initialValue: metrics.snapshot())
    }

    var body: some View {
        NavigationStack {
            List {
                if snapshot.isEmpty {
                    Text(verbatim: "No tile requests recorded yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach(snapshot.layers.filter { $0.total > 0 }) { layer in
                    Section {
                        summary(for: layer)
                        breakdown(for: layer)
                        NavigationLink {
                            zoomDetail(for: layer)
                        } label: {
                            Text(verbatim: "By zoom")
                        }
                    } header: {
                        Text(verbatim: "\(layer.server.debugName) — \(layer.total) requests")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Text(verbatim: "Reset counters")
                    }
                } footer: {
                    Text(verbatim: "Counting since \(snapshot.since.formatted(date: .abbreviated, time: .shortened)). "
                         + "Aggregates only — layer and zoom, never tile coordinates. Never leaves this device.")
                }
            }
            .navigationTitle(Text(verbatim: "Tile Metrics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        metrics.flush()
                        snapshot = metrics.snapshot()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .confirmationDialog(Text(verbatim: "Reset all tile counters?"),
                                isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button(role: .destructive) {
                    metrics.reset()
                    snapshot = metrics.snapshot()
                } label: {
                    Text(verbatim: "Reset")
                }
            }
        }
    }

    @ViewBuilder
    private func summary(for layer: TileMetrics.LayerStats) -> some View {
        row("Served without network", Self.percent(layer.localHitRate))
        row("Fault rate", Self.percent(layer.faultRate))
        row("Latency p50", Self.latency(layer.latencyPercentile(0.5)))
        row("Latency p95", Self.latency(layer.latencyPercentile(0.95)))
        if layer.retriedRequests > 0 {
            row("Retried requests", "\(layer.retriedRequests) (\(layer.retryAttempts) extra attempts)")
        }
    }

    @ViewBuilder
    private func breakdown(for layer: TileMetrics.LayerStats) -> some View {
        ForEach(TileMetrics.Source.allCases.filter { layer.count($0) > 0 }, id: \.rawValue) { source in
            row(source.label, "\(layer.count(source))  ·  \(Self.share(layer.count(source), of: layer.total))")
        }
    }

    private func zoomDetail(for layer: TileMetrics.LayerStats) -> some View {
        List {
            ForEach(layer.byZoom) { zoom in
                Section {
                    ForEach(TileMetrics.Source.allCases.filter { (zoom.counts[$0] ?? 0) > 0 }, id: \.rawValue) { source in
                        row(source.label, "\(zoom.counts[source] ?? 0)")
                    }
                } header: {
                    Text(verbatim: "z\(zoom.z) — \(zoom.total) requests")
                }
            }
        }
        .navigationTitle(Text(verbatim: layer.server.debugName))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } label: {
            Text(verbatim: title)
        }
    }

    // MARK: - Formatting

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f %%", value * 100)
    }

    private static func share(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.1f %%", Double(count) / Double(total) * 100)
    }

    /// Reported as the bucket bound rather than an interpolated figure: the
    /// histogram genuinely does not know where inside the bucket the sample
    /// fell, and a fabricated "127 ms" would imply precision that isn't there.
    private static func latency(_ value: (milliseconds: Int, isOverflow: Bool)?) -> String {
        guard let value else { return "—" }
        let formatted = value.milliseconds >= 1000
            ? String(format: "%.0f s", Double(value.milliseconds) / 1000)
            : "\(value.milliseconds) ms"
        return value.isOverflow ? "> \(formatted)" : "≤ \(formatted)"
    }
}

#Preview {
    DebugSheet()
}
