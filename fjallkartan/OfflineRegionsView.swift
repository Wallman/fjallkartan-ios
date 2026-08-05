import MapKit
import SwiftUI

/// Owns the offline tile store's region list plus any in-flight downloaders,
/// so `OfflineRegionsSheet` and its rows can show live progress.
@MainActor
@Observable
final class OfflineRegionsModel {
    let store: OfflineTileStore
    private(set) var regions: [OfflineTileStore.RegionSummary] = []
    private(set) var activeDownloaders: [String: OfflineRegionDownloader] = [:]

    var onRegionDownloadCompleted: () -> Void = { ReviewPrompter.shared.recordSuccessfulRegionDownload() }

    init(store: OfflineTileStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        regions = store.regions()
    }

    func downloader(for regionID: String) -> OfflineRegionDownloader? {
        activeDownloaders[regionID]
    }

    /// Starts a new region download, or resumes one that was interrupted
    /// (same `regionID`, re-enumerates and skips tiles already on disk).
    func startDownload(name: String, rect: MKMapRect, regionID: String = UUID().uuidString) {
        let downloader = OfflineRegionDownloader(store: store)
        activeDownloaders[regionID] = downloader
        downloader.start(regionID: regionID, name: name, rect: rect)
        refresh()
        watch(regionID: regionID, downloader: downloader)
    }

    func pause(_ regionID: String) {
        activeDownloaders[regionID]?.pause()
    }

    func resume(_ regionID: String) {
        guard let region = store.regions().first(where: { $0.id == regionID }) else { return }
        // A prior downloader instance may already be gone (e.g. after the app
        // relaunched); start() transparently resumes from what's on disk.
        if let downloader = activeDownloaders[regionID] {
            downloader.resume()
        } else {
            startDownload(name: region.name, rect: region.mapRect, regionID: regionID)
        }
    }

    func delete(_ regionID: String) {
        activeDownloaders[regionID]?.cancel()
        activeDownloaders[regionID] = nil
        try? store.deleteRegion(id: regionID)
        refresh()
    }

    /// Polls a downloader until it settles, refreshing `regions` so the list
    /// reflects on-disk progress and clearing it from `activeDownloaders`
    /// once there is nothing left to observe live.
    private func watch(regionID: String, downloader: OfflineRegionDownloader) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.activeDownloaders[regionID] === downloader else { return }
                self.refresh()
                if downloader.status == .completed || downloader.status == .cancelled {
                    let didComplete = downloader.status == .completed
                    self.activeDownloaders[regionID] = nil
                    self.refresh()
                    if didComplete { self.onRegionDownloadCompleted() }
                    return
                }
            }
        }
    }
}

private extension OfflineTileStore.RegionSummary {
    var mapRect: MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: minLon))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

private let regionNameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

/// The area actually offered for download: an inset of the visible
/// viewport, matching the dashed preview rectangle drawn on the map.
func offlineRegionPreviewRect(for currentRect: MKMapRect) -> MKMapRect {
    currentRect.insetBy(dx: currentRect.width * 0.1, dy: currentRect.height * 0.1)
}

/// Sheet listing already-downloaded regions (pause/resume/delete). Creating
/// a *new* region happens inline on the map via `RegionDownloadBar`, so this
/// sheet no longer covers the map/preview rectangle.
struct OfflineRegionsSheet: View {
    @Bindable var model: OfflineRegionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.regions.isEmpty {
                    ContentUnavailableView(
                        "No offline regions",
                        systemImage: "arrow.down.circle",
                        description: Text("Tap the download button on the map to save an area for offline use.")
                    )
                } else {
                    List {
                        ForEach(model.regions) { region in
                            RegionRow(model: model, region: region)
                        }
                    }
                }
            }
            .navigationTitle("Offline regions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RegionDownloadBar: View {
    @Bindable var model: OfflineRegionsModel
    let rect: MKMapRect
    let onDownload: () -> Void

    private var estimate: (tileCount: Int, bytes: Int) {
        TilePyramid.estimate(rect: rect)
    }

    private var exceedsGuard: Bool {
        estimate.bytes > TilePyramid.maxDownloadBytes
    }

    private var insufficientStorage: Bool {
        guard let available = OfflineTileStore.availableCapacityBytes else { return false }
        return estimate.bytes > available
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("≈ \(sizeLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if exceedsGuard {
                Text("This area is too large to download. Zoom in and try a smaller region.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if insufficientStorage {
                Text("Not enough free space on this device to download this area.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                model.startDownload(name: regionNameFormatter.string(from: Date()), rect: rect)
                onDownload()
            } label: {
                Label("Download this area", systemImage: "arrow.down.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(exceedsGuard || insufficientStorage ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.orange.opacity(exceedsGuard || insufficientStorage ? 0 : 0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(exceedsGuard || insufficientStorage)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }
}

private struct RegionRow: View {
    let model: OfflineRegionsModel
    let region: OfflineTileStore.RegionSummary
    @State private var isConfirmingDelete = false

    private var downloader: OfflineRegionDownloader? { model.downloader(for: region.id) }

    private var isDownloading: Bool { downloader?.status == .downloading }
    private var isPaused: Bool { downloader?.status == .paused || region.status == .paused }

    private var failureMessage: String? {
        if case .failed(let message) = downloader?.status { return message }
        return region.status == .failed ? String(localized: "Download failed.") : nil
    }

    private var doneFraction: Double {
        guard let downloader, downloader.tilesTotal > 0 else {
            return region.tileTotal > 0 ? Double(region.tileDone) / Double(region.tileTotal) : 1
        }
        return Double(downloader.tilesDone) / Double(downloader.tilesTotal)
    }

    private var bytes: Int { downloader?.bytesDownloaded ?? region.bytes }

    var body: some View {
        HStack {
            if isDownloading || isPaused {
                ProgressView(value: doneFraction)
                    .progressViewStyle(.circular)
                    .frame(width: 24, height: 24)
            } else if failureMessage != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(region.name)
                    .font(.body)
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isDownloading {
                Button {
                    model.pause(region.id)
                } label: {
                    Image(systemName: "pause.circle")
                }
                .buttonStyle(.borderless)
            } else if isPaused {
                Button {
                    model.resume(region.id)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
            } else if failureMessage != nil {
                Button {
                    model.resume(region.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .confirmationDialog(
                "Delete this offline region?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    model.delete(region.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the downloaded area for \"\(region.name)\" from this device.")
            }
        }
    }
}
