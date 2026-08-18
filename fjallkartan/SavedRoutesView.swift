import SwiftUI

@MainActor
@Observable
final class SavedRoutesModel {
    let store: SavedRouteStore
    private(set) var routes: [SavedRoute] = []

    init(store: SavedRouteStore) {
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
        routes = store.load()
    }

    func save(_ route: SavedRoute) {
        try? store.save(route)
        refresh()
    }

    func delete(_ route: SavedRoute) {
        store.delete(route)
        refresh()
    }

    func rename(_ route: SavedRoute, to name: String) {
        try? store.rename(route, to: name)
        refresh()
    }

    func nextDefaultName() -> String {
        let taken = Set(routes.compactMap(\.name))
        var number = 1
        while taken.contains(Self.defaultName(number)) { number += 1 }
        return Self.defaultName(number)
    }

    static func defaultName(_ number: Int) -> String {
        String(localized: "Route \(number)")
    }
}

struct SavedRoutesSheet: View {
    @Bindable var model: SavedRoutesModel
    let hasUnsavedRoute: Bool
    let onSelect: (SavedRoute) -> Void
    var featured: [FeaturedRoute] = FeaturedRoutes.all
    @Environment(\.dismiss) private var dismiss
    @State private var renamingRoute: SavedRoute?

    var body: some View {
        NavigationStack {
            List {
                Section("Your routes") {
                    if model.routes.isEmpty {
                        Text("Save a measurement to see it here.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.routes) { route in
                        HStack {
                            SavedRouteRowButton(route: route,
                                                hasUnsavedRoute: hasUnsavedRoute) {
                                onSelect(route)
                                dismiss()
                            }
                            DeleteRouteButton(route: route) {
                                model.delete(route)
                            }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                renamingRoute = route
                            }
                        }
                    }
                }

                if !featured.isEmpty {
                    Section {
                        ForEach(featured) { entry in
                            SavedRouteRowButton(route: entry.route,
                                                subtitle: entry.subtitle,
                                                hasUnsavedRoute: hasUnsavedRoute) {
                                onSelect(entry.route)
                                dismiss()
                            }
                        }
                    } header: {
                        Text("Suggested routes")
                    }
                }
            }
            .navigationTitle("Saved routes")
            .sheet(item: $renamingRoute) { route in
                RouteNameSheet(title: "Rename route",
                               initialName: route.displayName) { name in
                    model.rename(route, to: name)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SavedRouteRowButton: View {
    let route: SavedRoute
    var subtitle: String?
    let hasUnsavedRoute: Bool
    let onConfirm: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button {
            if hasUnsavedRoute {
                isConfirming = true
            } else {
                onConfirm()
            }
        } label: {
            SavedRouteRow(route: route, subtitle: subtitle)
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Replace current route?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current measurement isn't saved and will be lost.")
        }
    }
}

/// Mirrors the offline-region rows: an explicit trash button with a
/// confirmation, rather than a hidden swipe action.
private struct DeleteRouteButton: View {
    let route: SavedRoute
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .confirmationDialog(
            "Delete this route?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(route.displayName)\" from this device.")
        }
    }
}

private struct SavedRouteRow: View {
    let route: SavedRoute
    var subtitle: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(route.formattedDistance)
                    if route.hasElevation {
                        climb("arrow.up", route.formattedAscent)
                        climb("arrow.down", route.formattedDescent)
                    }
                }
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// A tight arrow-and-number pair. `Label` would draw the glyph at the full
    /// text size with its own spacing, which crowds the row.
    private func climb(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(value)
        }
    }
}
