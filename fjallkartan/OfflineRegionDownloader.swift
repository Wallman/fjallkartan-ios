import CoreLocation
import Foundation
import MapKit
import UIKit

/// Downloads every tile in the fixed z7–z14 pyramid (`TilePyramid`) for a
/// user-picked region into `OfflineTileStore`, with pause/resume.
@MainActor
@Observable
final class OfflineRegionDownloader {
    enum Status: Equatable {
        case idle
        case downloading
        case paused
        case completed
        case failed(String)
        case cancelled
    }

    private(set) var status: Status = .idle
    private(set) var tilesDone = 0
    private(set) var tilesTotal = 0
    private(set) var bytesDownloaded = 0

    private let store: OfflineTileStore
    private let fetcher: TileFetcher
    private var isPaused = false
    private var isCancelled = false
    private var writeFailureMessage: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var runningTask: Task<Void, Never>?

    /// `session` is overridable so tests can inject a stubbed `URLProtocol`.
    init(store: OfflineTileStore, session: URLSession? = nil, cache: URLCache? = TileFetcher.sharedTileCache) {
        self.store = store
        let session = session ?? {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 4
            config.urlCache = nil
            return URLSession(configuration: config)
        }()
        self.fetcher = TileFetcher(session: session, cache: cache, storesResponses: false)
    }

    /// Starts (or resumes, if `regionID` already exists) downloading `rect`.
    func start(regionID: String, name: String, rect: MKMapRect) {
        guard status != .downloading else { return }
        isCancelled = false
        isPaused = false

        let region = MKCoordinateRegion(rect)
        let jobs = TilePyramid.jobs(in: rect)

        let existing = store.existingTileKeys(regionID: regionID)
        let remaining = jobs.filter {
            !existing.contains(.init(server: $0.server.storeCode, z: Int($0.path.z), x: Int($0.path.x), y: Int($0.path.y)))
        }

        tilesTotal = jobs.count
        tilesDone = existing.count
        // Seed with this region's own already-downloaded bytes (0 for a brand-new region)
        bytesDownloaded = store.regions().first(where: { $0.id == regionID })?.bytes ?? 0
        status = .downloading

        if existing.isEmpty {
            try? store.createRegion(id: regionID, name: name,
                                    minLat: region.center.latitude - region.span.latitudeDelta / 2,
                                    minLon: region.center.longitude - region.span.longitudeDelta / 2,
                                    maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                                    maxLon: region.center.longitude + region.span.longitudeDelta / 2,
                                    minZ: TilePyramid.minZoom, maxZ: TilePyramid.maxZoom,
                                    tileTotal: jobs.count)
        }

        beginBackgroundTask()
        runningTask = Task { [weak self] in
            await self?.run(jobs: remaining, regionID: regionID)
        }
    }

    func pause() {
        guard status == .downloading else { return }
        isPaused = true
        status = .paused
    }

    func resume() {
        guard status == .paused else { return }
        isPaused = false
        status = .downloading
    }

    func cancel() {
        isCancelled = true
        runningTask?.cancel()
        status = .cancelled
        endBackgroundTask()
    }

    // MARK: - Worker loop

    private static let maxConcurrent = 4
    private static let batchSize = 50

    private func run(jobs: [TilePyramid.Job], regionID: String) async {
        var buffer: [OfflineTileStore.PendingTile] = []
        let maxConcurrent = Self.maxConcurrent

        await withTaskGroup(of: OfflineTileStore.PendingTile?.self) { group in
            var iterator = jobs.makeIterator()
            var active = 0

            func addNext() {
                guard active < maxConcurrent, let job = iterator.next() else { return }
                active += 1
                group.addTask {
                    await Self.fetchTile(fetcher: self.fetcher, server: job.server, path: job.path)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }

            while active > 0, let result = await group.next() {
                active -= 1

                // Honor pause between completions rather than mid-flight.
                while isPaused, !isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if isCancelled { break }

                if let tile = result {
                    buffer.append(tile)
                    bytesDownloaded += tile.data.count
                }
                tilesDone += 1

                if buffer.count >= Self.batchSize {
                    flush(&buffer, regionID: regionID)
                    // A write failure (e.g. disk full) means further network
                    // fetches would be wasted work; stop immediately.
                    if writeFailureMessage != nil { break }
                }
                addNext()
            }
        }

        flush(&buffer, regionID: regionID)
        finish(regionID: regionID)
    }

    private func flush(_ buffer: inout [OfflineTileStore.PendingTile], regionID: String) {
        guard !buffer.isEmpty, writeFailureMessage == nil else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        do {
            try store.putTiles(batch, regionID: regionID)
        } catch {
            writeFailureMessage = error.localizedDescription
            return
        }
        try? store.updateRegionProgress(id: regionID, tileDone: tilesDone, bytes: bytesDownloaded,
                                        status: .downloading)
    }

    private func finish(regionID: String) {
        endBackgroundTask()
        if let message = writeFailureMessage {
            status = .failed(message)
            try? store.updateRegionProgress(id: regionID, tileDone: tilesDone, bytes: bytesDownloaded,
                                            status: .failed)
            return
        }
        guard !isCancelled else {
            try? store.updateRegionProgress(id: regionID, tileDone: tilesDone, bytes: bytesDownloaded,
                                            status: .paused)
            return
        }
        status = .completed
        try? store.updateRegionProgress(id: regionID, tileDone: tilesDone, bytes: bytesDownloaded,
                                        status: .complete)
    }

    private static func fetchTile(fetcher: TileFetcher, server: TileServer, path: MKTileOverlayPath) async -> OfflineTileStore.PendingTile? {
        let url = server.url(z: Int(path.z), x: Int(path.x), y: Int(path.y))
        let outcome = await withCheckedContinuation { continuation in
            fetcher.fetch(url: url, server: server) { continuation.resume(returning: $0) }
        }
        guard case .success(let data) = outcome else { return nil }
        return OfflineTileStore.PendingTile(server: server.storeCode, z: Int(path.z), x: Int(path.x), y: Int(path.y), data: data)
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "OfflineRegionDownload") { [weak self] in
            // The OS is about to reclaim our background time. Pause first so
            // the run loop stops issuing new requests (it's resumable), then
            // release the task — otherwise work keeps running unprotected
            // past the time budget and risks the app being killed mid-flush.
            self?.pause()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
