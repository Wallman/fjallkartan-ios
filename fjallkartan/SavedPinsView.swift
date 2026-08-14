import SwiftUI

@MainActor
@Observable
final class SavedPinsModel {
    let store: SavedPinStore
    private(set) var pins: [SavedPin] = []

    init(store: SavedPinStore) {
        self.store = store
        refresh()
        Task { [weak self] in
            guard let self else { return }
            // Resolves lazily so first launch isn't blocked on network/disk I/O
            await store.syncWithiCloudIfAvailable()
            self.refresh()
            store.startObservingRemoteChanges { [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        pins = store.load()
    }

    func save(_ pin: SavedPin) {
        try? store.save(pin)
        refresh()
    }

    func delete(_ pin: SavedPin) {
        store.delete(pin)
        refresh()
    }
}
