import MapLibre
import SwiftUI

enum DebugSettings {
    static let showsZoomOverlayKey = "debug.showsZoomOverlay"
}

struct DebugSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DebugSettings.showsZoomOverlayKey) private var showsZoomOverlay = false
    @State private var exportedLogURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var isClearingTileCache = false
    @State private var tileCacheClearedMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $showsZoomOverlay) {
                    Text(verbatim: "Show zoom level")
                }
                .accessibilityIdentifier("debug.showsZoomOverlay")
                Section {
                    Button {
                        exportLogs()
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text(verbatim: "Export logs")
                        }
                    }
                    .disabled(isExporting)
                    if let exportError {
                        Text(verbatim: exportError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        clearTileCache()
                    } label: {
                        if isClearingTileCache {
                            ProgressView()
                        } else {
                            Text(verbatim: "Clear tile cache")
                        }
                    }
                    .disabled(isClearingTileCache)
                    .accessibilityIdentifier("debug.clearTileCache")
                    if let tileCacheClearedMessage {
                        Text(verbatim: tileCacheClearedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("debug.tileCacheClearedMessage")
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Debug"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                        .accessibilityIdentifier("debug.done")
                }
            }
            .sheet(item: $exportedLogURL) { url in
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func exportLogs() {
        exportError = nil
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let url = try LogExporter.exportLogs()
                await MainActor.run {
                    exportedLogURL = url
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    if error is LogExporter.ExportError {
                        exportError = "No logs recorded yet. Reproduce the issue, then try again."
                    } else {
                        exportError = "Export failed: \(error.localizedDescription)"
                    }
                    isExporting = false
                }
            }
        }
    }

    private func clearTileCache() {
        tileCacheClearedMessage = nil
        isClearingTileCache = true
        URLCache.shared.removeAllCachedResponses()
        MLNOfflineStorage.shared.clearAmbientCache { error in
            isClearingTileCache = false
            if let error {
                tileCacheClearedMessage = "Failed to clear: \(error.localizedDescription)"
            } else {
                tileCacheClearedMessage = "Tile cache cleared."
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    DebugSheet()
}
