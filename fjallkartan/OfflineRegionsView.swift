import MapKit
import MapLibre
import SwiftUI
import BackgroundTasks
import OSLog
import UIKit

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
    let userPaused: Bool
}

@MainActor
@Observable
final class OfflineRegionsModel {
    static let shared = OfflineRegionsModel()
    
    private(set) var regions: [RegionSummary] = []

    private(set) var hasInterruptedDownloads = false
    private var didPromptForInterruptedDownloads = false

    private(set) var shouldShowLegacyRegionsWipedAlert = false

    private var failureMessages: [String: String] = [:]

    private var elevationProgressByID: [String: (done: Int, total: Int, bytes: Int)] = [:]
    private var elevationTasks: [String: Task<Void, Never>] = [:]
    private var initialProgressRequestedIDs: Set<String> = []

    @ObservationIgnored private nonisolated(unsafe) var progressObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var errorObserver: NSObjectProtocol?
    @ObservationIgnored private var packsObserver: NSKeyValueObservation?

    private static let backgroundTaskIdentifierPrefix = "fjallkartan.fjallkartan.offline-download."
    private static let backgroundTaskConcreteIdentifier = backgroundTaskIdentifierPrefix + "active"

    private static let backgroundLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan",
                                              category: "OfflineBackgroundTask")

    @ObservationIgnored private var backgroundContinuation: Any?

    var hasActiveBackgroundContinuation: Bool { backgroundContinuation != nil }

    @available(iOS 26, *)
    static func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskConcreteIdentifier, using: nil) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            backgroundLog.notice("continuation launch handler invoked")
            Task { @MainActor in
                OfflineRegionsModel.shared.attachBackgroundContinuation(continuedTask)
            }
        }
        backgroundLog.notice("registerBackgroundTask: registered=\(registered, privacy: .public)")
    }

    /// `MLNOfflineStorage` pauses when the app is backgrounded, removing
    /// this observer is what lets a download keep going while the continuation.
    @available(iOS 26, *)
    static func allowBackgroundDownloads() {
        NotificationCenter.default.removeObserver(
            MLNOfflineStorage.shared,
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    init() {
        shouldShowLegacyRegionsWipedAlert = Self.performOneTimeWipeIfNeeded()
        packsObserver = MLNOfflineStorage.shared.observe(\.packs, options: [.new]) { _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
        observeNotifications()
    }

    private static let didWipeLegacyRegionsKey = "OfflineRegionsModel.didWipeLegacyRegions"

    @discardableResult
    private static func performOneTimeWipeIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: didWipeLegacyRegionsKey) else { return false }

        for pack in MLNOfflineStorage.shared.packs ?? [] {
            MLNOfflineStorage.shared.removePack(pack) { _ in }
        }

        let legacyElevationDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElevationTiles", isDirectory: true)
        let hadLegacyData = FileManager.default.fileExists(atPath: legacyElevationDirectory.path)
        try? FileManager.default.removeItem(at: legacyElevationDirectory)

        UserDefaults.standard.removeObject(forKey: pausedIDsDefaultsKey)
        UserDefaults.standard.set(true, forKey: didWipeLegacyRegionsKey)
        return hadLegacyData
    }

    func dismissLegacyRegionsWipedAlert() {
        shouldShowLegacyRegionsWipedAlert = false
    }
    
    func refresh() {
        let allInfos = OfflineRegionsStore.shared.allRegions()

        let needsPacks = allInfos.contains { !$0.completed }
        let packsByMLNRegionID: [Int64: MLNOfflinePack] = needsPacks
            ? Dictionary(
                uniqueKeysWithValues: (MLNOfflineStorage.shared.packs ?? [])
                    .filter { $0.state != .invalid }
                    .compactMap { pack in pack.regionId.map { ($0.int64Value, pack) } }
            )
            : [:]

        var summaries: [RegionSummary] = []

        for info in allInfos {
            let pack = info.mlnRegionID.flatMap { packsByMLNRegionID[$0] }
            if !info.completed {
                ensureElevationTracking(id: info.id)
                if let pack, initialProgressRequestedIDs.insert(info.id).inserted {
                    pack.requestProgress()
                }
            } else if elevationProgressByID[info.id] == nil {
                let progress = OfflineRegionsStore.shared.regionProgress(id: info.id)
                elevationProgressByID[info.id] = (done: progress.count, total: progress.count, bytes: progress.bytes)
            }

            let elevation = elevationProgressByID[info.id] ?? (done: 0, total: 0, bytes: 0)
            let elevationComplete = elevation.done >= elevation.total

            let status: RegionSummary.Status
            if let message = failureMessages[info.id] {
                status = .failed(message)
            } else if info.completed {
                status = .complete
            } else if let pack {
                switch pack.state {
                case .complete:
                    if elevationComplete {
                        status = .complete
                    } else {
                        status = elevationTasks[info.id] != nil ? .downloading : .paused
                    }
                case .inactive: status = .paused
                default: status = .downloading
                }
            } else {
                status = .downloading
            }

            if status == .paused, !info.paused {
                noteInterruptedDownload()
            }

            
            if status == .complete, let pack, !info.completed {
                ReviewPrompter.shared.recordSuccessfulRegionDownload()
                OfflineRegionsStore.shared.setSize(info.id, bytes: Int64(pack.progress.countOfBytesCompleted) + Int64(elevation.bytes))
                OfflineRegionsStore.shared.setCompleted(info.id)
            }

            
            let bytes = status == .complete
                ? Int(info.size ?? (Int64(pack?.progress.countOfBytesCompleted ?? 0) + Int64(elevation.bytes)))
                : Int(pack?.progress.countOfBytesCompleted ?? 0) + elevation.bytes

            summaries.append(RegionSummary(
                id: info.id,
                name: info.name,
                createdAt: info.createdAt,
                resourcesDone: Int(pack?.progress.countOfResourcesCompleted ?? 0) + elevation.done,
                resourcesExpected: Int(pack?.progress.countOfResourcesExpected ?? 0) + elevation.total,
                bytes: bytes,
                status: status,
                userPaused: info.paused
            ))
        }

        regions = summaries.sorted { $0.createdAt > $1.createdAt }

        updateBackgroundContinuationProgress()
    }

    private func ensureBackgroundContinuationRequested() {
        guard #available(iOS 26, *) else { return }
        guard backgroundContinuation == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.backgroundTaskConcreteIdentifier,
            title: String(localized: "Downloading offline map"),
            subtitle: String(localized: "Preparing…")
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.backgroundLog.notice("submitted continuation request")
        } catch {
            Self.backgroundLog.error("failed to submit continuation request: \(error.localizedDescription, privacy: .public)")
        }
    }

    @available(iOS 26, *)
    private func attachBackgroundContinuation(_ task: BGContinuedProcessingTask) {
        Self.backgroundLog.notice("continuation attached")
        backgroundContinuation = task
        NorwayTileProxy.ensureRunning()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                Self.backgroundLog.notice("continuation expired")
                // System-revoked continuation: pause rather than let packs
                // keep transferring with no runtime left to track them.
                self?.suspendDownloadingRegions()
                self?.finishBackgroundContinuation(success: false)
            }
        }
        updateBackgroundContinuationProgress()
    }

    private func suspendDownloadingRegions() {
        for region in regions where region.status == .downloading {
            mlnPack(for: region.id)?.suspend()
            elevationTasks[region.id]?.cancel()
            elevationTasks[region.id] = nil
        }
        refresh()
    }

    @available(iOS 26, *)
    private func finishBackgroundContinuation(success: Bool) {
        guard let task = backgroundContinuation as? BGContinuedProcessingTask else { return }
        Self.backgroundLog.notice("continuation finished, success=\(success, privacy: .public)")
        backgroundContinuation = nil
        task.setTaskCompleted(success: success)
        if UIApplication.shared.applicationState != .active {
            NorwayTileProxy.stop()
        }
    }

    private func updateBackgroundContinuationProgress() {
        guard #available(iOS 26, *) else { return }
        let downloading = regions.filter { $0.status == .downloading }

        guard let task = backgroundContinuation as? BGContinuedProcessingTask else {
            return
        }

        guard !downloading.isEmpty else {
            finishBackgroundContinuation(success: true)
            return
        }

        let done = downloading.reduce(0) { $0 + $1.resourcesDone }
        let expected = max(downloading.reduce(0) { $0 + $1.resourcesExpected }, 1)
        task.progress.totalUnitCount = Int64(expected)
        task.progress.completedUnitCount = Int64(done)
        let subtitle = downloading.count > 1
            ? String(localized: "\(downloading.count) regions")
            : downloading[0].name
        task.updateTitle(String(localized: "Downloading offline map"), subtitle: subtitle)
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
              let id = decodeContext(pack) else { return }
        let region = regions.first { $0.id == id }
        // Gate on `regions` already reflecting a settled status, not on the
        // DB's `userPaused` flag alone — after a force quit, a user-paused
        // region's flag is already true before its pack has ever been
        // queried this launch, and skipping here would leave `regions`
        // stuck showing its stale pre-resolve numbers forever.
        guard region?.status != .complete, region?.status != .paused else { return }
        failureMessages[id] = nil
        if pack.state == .inactive, !(region?.userPaused ?? false) {
            noteInterruptedDownload()
        }
        refresh()
    }

    private func handleError(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let id = decodeContext(pack) else { return }
        let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        failureMessages[id] = error?.localizedDescription ?? String(localized: "Download failed.")
        refresh()
    }

    private func decodeContext(_ pack: MLNOfflinePack) -> String? {
        try? JSONDecoder().decode(String.self, from: pack.context)
    }

    private static let pausedIDsDefaultsKey = "OfflineRegionsModel.pausedIDs"

    func resumeInterruptedDownloads() {
        for region in regions where region.status == .paused && !region.userPaused {
            resume(region.id)
        }
        hasInterruptedDownloads = false
    }

    func dismissInterruptedDownloadsPrompt() {
        hasInterruptedDownloads = false
    }

    /// `refresh()` runs constantly, so the prompt is armed at most once per
    /// launch — otherwise dismissing it would just bring it straight back.
    private func noteInterruptedDownload() {
        guard !didPromptForInterruptedDownloads else { return }
        didPromptForInterruptedDownloads = true
        hasInterruptedDownloads = true
    }

    private func ensureElevationTracking(id: String) {
        guard elevationProgressByID[id] == nil else { return }
        let progress = OfflineRegionsStore.shared.regionProgress(id: id)
        let total = OfflineRegionsStore.shared.allKeys(regionID: id).count
        elevationProgressByID[id] = (done: progress.count, total: total, bytes: progress.bytes)
    }

    private func startElevationDownload(id: String, keys: [ElevationService.TileKey]? = nil) {
        elevationTasks[id] = Task { @MainActor [weak self] in
            defer { self?.elevationTasks[id] = nil }
            let resolvedKeys: [ElevationService.TileKey]
            if let keys {
                resolvedKeys = keys
            } else {
                resolvedKeys = await Task.detached {
                    OfflineRegionsStore.shared.allKeys(regionID: id)
                }.value
            }
            guard !resolvedKeys.isEmpty else { return }

            // Filter out already-downloaded tiles in bulk up front, rather
            // than letting `prefetchTiles` re-check each one individually —
            // on resume, a big mostly-finished region could otherwise run
            // thousands of SQLite lookups.
            let (alreadyFetched, baseline) = await Task.detached {
                (OfflineRegionsStore.shared.fetchedKeys(regionID: id),
                 OfflineRegionsStore.shared.regionProgress(id: id))
            }.value
            let missingKeys = resolvedKeys.filter { !alreadyFetched.contains($0) }
            let total = resolvedKeys.count
            self?.elevationProgressByID[id] = (done: baseline.count, total: total, bytes: baseline.bytes)
            guard !missingKeys.isEmpty else { return }

            var lastRefresh = Date.distantPast
            await ElevationService.shared.prefetchTiles(missingKeys) { done, _, bytes in
                self?.elevationProgressByID[id] = (done: baseline.count + done, total: total, bytes: baseline.bytes + bytes)
                let now = Date()
                if baseline.count + done == total || now.timeIntervalSince(lastRefresh) > 0.2 {
                    lastRefresh = now
                    self?.refresh()
                }
            }
        }
    }

    func startDownload(name: String, rect: MKMapRect) {
        let id = UUID().uuidString
        guard let contextData = try? JSONEncoder().encode(id) else { return }

        let region = MLNTilePyramidOfflineRegion(
            styleURL: MapView.buildStyleURL(),
            bounds: MLNCoordinateBounds(mapRect: rect),
            fromZoomLevel: Double(TilePyramid.minZoom),
            toZoomLevel: Double(TilePyramid.maxZoom)
        )

        let keys = ElevationService.tileKeys(coveringRect: rect)
        elevationProgressByID[id] = (done: 0, total: keys.count, bytes: 0)

        OfflineRegionsStore.shared.insertRegion(id: id, name: name, createdAt: Date())
        OfflineRegionsStore.shared.linkTiles(regionID: id, keys: keys)

        MLNOfflineStorage.shared.addPack(for: region, withContext: contextData) { [weak self] pack, _ in
            guard let pack else { return }
            if let mlnRegionID = pack.regionId?.int64Value {
                OfflineRegionsStore.shared.setMLNRegionID(id, mlnRegionID: mlnRegionID)
            }
            pack.resume()
            Task { @MainActor [weak self] in
                self?.startElevationDownload(id: id, keys: keys)
                self?.refresh()
                self?.ensureBackgroundContinuationRequested()
            }
        }
    }

    private func mlnPack(for regionID: String) -> MLNOfflinePack? {
        guard let mlnRegionID = OfflineRegionsStore.shared.mlnRegionID(for: regionID) else { return nil }
        return (MLNOfflineStorage.shared.packs ?? []).first { $0.regionId?.int64Value == mlnRegionID }
    }

    func pause(_ regionID: String) {
        OfflineRegionsStore.shared.setPaused(regionID, true)
        mlnPack(for: regionID)?.suspend()
        elevationTasks[regionID]?.cancel()
        elevationTasks[regionID] = nil
        refresh()
    }

    func resume(_ regionID: String) {
        guard let pack = mlnPack(for: regionID) else { return }
        OfflineRegionsStore.shared.setPaused(regionID, false)
        failureMessages[regionID] = nil
        pack.resume()
        startElevationDownload(id: regionID)
        refresh()
        ensureBackgroundContinuationRequested()
    }

    func delete(_ regionID: String) {
        failureMessages[regionID] = nil
        elevationTasks[regionID]?.cancel()
        elevationTasks[regionID] = nil
        elevationProgressByID[regionID] = nil
        initialProgressRequestedIDs.remove(regionID)

        // Look up the pack before deleting the row — `mlnRegionID(for:)`
        // needs it to still exist.
        let pack = mlnPack(for: regionID)
        OfflineRegionsStore.shared.deleteRegion(id: regionID)
        if let pack {
            MLNOfflineStorage.shared.removePack(pack)
        }
        refresh()
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
                        .accessibilityIdentifier("offlineRegions.done")
                }
            }
        }
    }
}

struct RegionDownloadBar: View {
    @Bindable var model: OfflineRegionsModel
    let rect: MKMapRect
    let onDownload: () -> Void
    @State private var isNamingRegion = false
    @State private var estimate: (tileCount: Int, bytes: Int) = (0, 0)
    @State private var availableCapacityBytes: Int?

    private var exceedsGuard: Bool {
        estimate.bytes > TilePyramid.maxDownloadBytes
    }

    private var insufficientStorage: Bool {
        guard let available = availableCapacityBytes else { return false }
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
                isNamingRegion = true
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
            .accessibilityIdentifier("offlineRegions.startDownload")
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 300)
        .padding(.horizontal, 16)
        .onAppear {
            Task.detached(priority: .userInitiated) {
                let capacity = TilePyramid.availableCapacityBytes
                await MainActor.run { availableCapacityBytes = capacity }
            }
        }
        .onChange(of: "\(rect)", initial: true) { _, _ in
            let currentRect = rect
            Task.detached(priority: .userInitiated) {
                let computed = TilePyramid.estimate(rect: currentRect)
                await MainActor.run { estimate = computed }
            }
        }
        .routeNameAlert(
            "Name this region",
            isPresented: $isNamingRegion,
            initialName: ""
        ) { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            model.startDownload(
                name: trimmed.isEmpty ? regionNameFormatter.string(from: Date()) : trimmed,
                rect: rect
            )
            onDownload()
        }
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
            if isDownloading {
                ProgressView(value: doneFraction)
                    .progressViewStyle(.circular)
                    .frame(width: 20, height: 20)
            } else if isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            } else if failureMessage != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 20, height: 20)
                    .accessibilityIdentifier("offlineRegions.complete.\(region.name)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(region.name)
                    .font(.body)
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("offlineRegions.error.\(region.name)")
                } else {
                    Text(region.status == .complete
                        ? ByteCountFormatter.string(fromByteCount: Int64(region.bytes), countStyle: .file)
                        : "\(Int(doneFraction * 100))%")
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
                .accessibilityIdentifier("offlineRegions.pause.\(region.name)")
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
            .accessibilityIdentifier("offlineRegions.delete.\(region.name)")
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
