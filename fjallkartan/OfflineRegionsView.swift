import MapKit
import MapLibre
import SwiftUI

/// Arbitrary data JSON-encoded into an `MLNOfflinePack`'s `context`, since a
/// pack has no stable name/creation-date concept of its own
private struct RegionContext: Codable {
    let id: String
    let name: String
    let createdAt: Date
}

struct RegionSummary: Identifiable, Hashable {
    enum Status: Hashable {
        case downloading
        case paused
        case complete
        case failed(String)
    }

    let id: String
    let name: String
    let createdAt: Date
    let resourcesDone: Int
    let resourcesExpected: Int
    let bytes: Int
    let status: Status
}

@MainActor
@Observable
final class OfflineRegionsModel {
    private(set) var regions: [RegionSummary] = []

    var onRegionDownloadCompleted: () -> Void = { ReviewPrompter.shared.recordSuccessfulRegionDownload() }

    private var packsByID: [String: MLNOfflinePack] = [:]
    private var failureMessages: [String: String] = [:]

    private var elevationKeysByID: [String: [ElevationService.TileKey]] = [:]
    private var elevationProgressByID: [String: (done: Int, total: Int, bytes: Int)] = [:]
    private var elevationTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private nonisolated(unsafe) var progressObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var errorObserver: NSObjectProtocol?
    @ObservationIgnored private var packsObserver: NSKeyValueObservation?

    init() {
        packsObserver = MLNOfflineStorage.shared.observe(\.packs, options: [.new]) { _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
        observeNotifications()
    }

    deinit {
        let center = NotificationCenter.default
        if let progressObserver { center.removeObserver(progressObserver) }
        if let errorObserver { center.removeObserver(errorObserver) }
    }

    private func observeNotifications() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleProgressChanged(notification)
            }
        }
        errorObserver = NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackError, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleError(notification)
            }
        }
    }

    private func handleProgressChanged(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let context = decodeContext(pack) else { return }
        failureMessages[context.id] = nil
        refresh()
    }

    private func handleError(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let context = decodeContext(pack) else { return }
        let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        failureMessages[context.id] = error?.localizedDescription ?? String(localized: "Download failed.")
        refresh()
    }

    private func decodeContext(_ pack: MLNOfflinePack) -> RegionContext? {
        try? JSONDecoder().decode(RegionContext.self, from: pack.context)
    }

    private static let pausedIDsDefaultsKey = "OfflineRegionsModel.pausedIDs"

    private func isUserPaused(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.pausedIDsDefaultsKey) ?? []).contains(id)
    }

    private func setUserPaused(_ id: String, _ paused: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.pausedIDsDefaultsKey) ?? [])
        if paused { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: Self.pausedIDsDefaultsKey)
    }

    func refresh() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        var byID: [String: MLNOfflinePack] = [:]
        var summaries: [RegionSummary] = []

        for pack in packs {
            guard pack.state != .invalid, let context = decodeContext(pack) else { continue }
            if packsByID[context.id] == nil {
                pack.requestProgress()
                if !isUserPaused(context.id) {
                    pack.resume()
                }
            }
            byID[context.id] = pack
            ensureElevationTracking(id: context.id, pack: pack)

            let elevation = elevationProgressByID[context.id] ?? (done: 0, total: 0, bytes: 0)
            let elevationComplete = elevation.done >= elevation.total

            let status: RegionSummary.Status
            if let message = failureMessages[context.id] {
                status = .failed(message)
            } else {
                switch pack.state {
                case .complete: status = elevationComplete ? .complete : .downloading
                case .inactive: status = .paused
                default: status = .downloading
                }
            }

            // Only fire once per completion: `regions` is rebuilt every time,
            // so gate on this being the transition into `.complete` rather
            // than an already-settled pack.
            if status == .complete, regions.first(where: { $0.id == context.id })?.status != .complete {
                onRegionDownloadCompleted()
            }

            summaries.append(RegionSummary(
                id: context.id,
                name: context.name,
                createdAt: context.createdAt,
                resourcesDone: Int(pack.progress.countOfResourcesCompleted) + elevation.done,
                resourcesExpected: Int(pack.progress.countOfResourcesExpected) + elevation.total,
                bytes: Int(pack.progress.countOfBytesCompleted) + elevation.bytes,
                status: status
            ))
        }

        packsByID = byID
        regions = summaries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Makes sure a pack's elevation tiles are known and, if the pack is
    /// actively downloading, being fetched — covers both a freshly created
    /// pack and one restored from disk on a fresh launch, since the download
    /// `Task` itself never survives a relaunch.
    private func ensureElevationTracking(id: String, pack: MLNOfflinePack) {
        if elevationKeysByID[id] == nil {
            let keys = Self.elevationKeys(for: pack)
            elevationKeysByID[id] = keys
            let done = keys.filter(ElevationService.isTileCached).count
            elevationProgressByID[id] = (done: done, total: keys.count, bytes: 0)
        }
        let complete = (elevationProgressByID[id]?.done ?? 0) >= (elevationProgressByID[id]?.total ?? 0)
        if !complete, pack.state != .inactive, elevationTasks[id] == nil {
            startElevationDownload(id: id)
        }
    }

    private static func elevationKeys(for pack: MLNOfflinePack) -> [ElevationService.TileKey] {
        guard let region = pack.region as? MLNTilePyramidOfflineRegion else { return [] }
        return ElevationService.tileKeys(coveringRect: MKMapRect(bounds: region.bounds))
    }

    private func startElevationDownload(id: String) {
        guard let keys = elevationKeysByID[id], !keys.isEmpty else { return }
        elevationTasks[id] = Task { @MainActor [weak self] in
            await ElevationService.shared.prefetchTiles(keys) { done, total, bytes in
                self?.elevationProgressByID[id] = (done: done, total: total, bytes: bytes)
                self?.refresh()
            }
            self?.elevationTasks[id] = nil
        }
    }

    func startDownload(name: String, rect: MKMapRect) {
        let context = RegionContext(id: UUID().uuidString, name: name, createdAt: Date())
        guard let contextData = try? JSONEncoder().encode(context) else { return }

        let region = MLNTilePyramidOfflineRegion(
            styleURL: MapView.buildStyleURL(),
            bounds: MLNCoordinateBounds(mapRect: rect),
            fromZoomLevel: Double(TilePyramid.minZoom),
            toZoomLevel: Double(TilePyramid.maxZoom)
        )

        let keys = ElevationService.tileKeys(coveringRect: rect)
        elevationKeysByID[context.id] = keys
        elevationProgressByID[context.id] = (done: 0, total: keys.count, bytes: 0)

        MLNOfflineStorage.shared.addPack(for: region, withContext: contextData) { [weak self] pack, _ in
            guard let pack else { return }
            pack.resume()
            Task { @MainActor [weak self] in
                self?.startElevationDownload(id: context.id)
                self?.refresh()
            }
        }
    }

    func pause(_ regionID: String) {
        setUserPaused(regionID, true)
        packsByID[regionID]?.suspend()
        elevationTasks[regionID]?.cancel()
        elevationTasks[regionID] = nil
        refresh()
    }

    func resume(_ regionID: String) {
        guard let pack = packsByID[regionID] else { return }
        setUserPaused(regionID, false)
        failureMessages[regionID] = nil
        pack.resume()
        startElevationDownload(id: regionID)
        refresh()
    }

    func delete(_ regionID: String) {
        guard let pack = packsByID[regionID] else { return }
        setUserPaused(regionID, false)
        failureMessages[regionID] = nil
        elevationTasks[regionID]?.cancel()
        elevationTasks[regionID] = nil

        // A tile can be shared with another downloaded region (overlapping
        // areas), so only delete the ones no other tracked region still needs.
        let ownKeys = Set(elevationKeysByID[regionID] ?? [])
        let keysStillNeeded = elevationKeysByID
            .filter { $0.key != regionID }
            .reduce(into: Set<ElevationService.TileKey>()) { $0.formUnion($1.value) }
        let keysToDelete = ownKeys.subtracting(keysStillNeeded)
        elevationKeysByID[regionID] = nil
        elevationProgressByID[regionID] = nil
        if !keysToDelete.isEmpty {
            Task.detached(priority: .utility) { ElevationService.deleteTiles(keysToDelete) }
        }

        MLNOfflineStorage.shared.removePack(pack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}

private extension MLNCoordinateBounds {
    init(mapRect: MKMapRect) {
        let northwest = MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate
        let southeast = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate
        self.init(
            sw: CLLocationCoordinate2D(latitude: southeast.latitude, longitude: northwest.longitude),
            ne: CLLocationCoordinate2D(latitude: northwest.latitude, longitude: southeast.longitude)
        )
    }
}

private extension MKMapRect {
    init(bounds: MLNCoordinateBounds) {
        let northwest = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.ne.latitude, longitude: bounds.sw.longitude))
        let southeast = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.sw.latitude, longitude: bounds.ne.longitude))
        self.init(
            x: min(northwest.x, southeast.x),
            y: min(northwest.y, southeast.y),
            width: abs(southeast.x - northwest.x),
            height: abs(southeast.y - northwest.y)
        )
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
        guard let available = TilePyramid.availableCapacityBytes else { return false }
        return estimate.bytes > available
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: "≈ \(sizeLabel)")
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
        .background(Color(.systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 300)
        .padding(.horizontal, 16)
    }
}

private struct RegionRow: View {
    let model: OfflineRegionsModel
    let region: RegionSummary
    @State private var isConfirmingDelete = false

    private var isDownloading: Bool { region.status == .downloading }
    private var isPaused: Bool { region.status == .paused }

    private var failureMessage: String? {
        if case .failed(let message) = region.status { return message }
        return nil
    }

    private var doneFraction: Double {
        region.resourcesExpected > 0 ? Double(region.resourcesDone) / Double(region.resourcesExpected) : 1
    }

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
                    Text(ByteCountFormatter.string(fromByteCount: Int64(region.bytes), countStyle: .file))
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

#Preview {
    ContentView()
}
