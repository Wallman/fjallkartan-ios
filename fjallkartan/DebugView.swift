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

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $showsZoomOverlay) {
                    Text(verbatim: "Show zoom level")
                }
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
            }
            .navigationTitle(Text(verbatim: "Debug"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
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
