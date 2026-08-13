import SwiftUI

@MainActor
@Observable
final class SavedRoutesModel {
    let store: SavedRouteStore
    private(set) var routes: [SavedRoute] = []

    init(store: SavedRouteStore) {
        self.store = store
        refresh()
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
}

struct SavedRoutesSheet: View {
    @Bindable var model: SavedRoutesModel
    let hasUnsavedRoute: Bool
    let onSelect: (SavedRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.routes.isEmpty {
                    ContentUnavailableView(
                        "No saved routes",
                        systemImage: "bookmark",
                        description: Text("Save a measurement to see it here.")
                    )
                } else {
                    List {
                        ForEach(model.routes) { route in
                            SavedRouteRowButton(route: route,
                                                hasUnsavedRoute: hasUnsavedRoute) {
                                onSelect(route)
                                dismiss()
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.delete(model.routes[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Saved routes")
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
            SavedRouteRow(route: route)
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

private struct SavedRouteRow: View {
    let route: SavedRoute

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(route.formattedDistance)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
