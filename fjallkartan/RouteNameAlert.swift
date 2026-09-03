import SwiftUI

/// Names a route, both when saving a fresh measurement and when renaming a
/// saved one, and also used to name a new offline region.
///
/// Implemented as `.alert`s rather than a small fixed-height sheet: a sheet
/// short enough to look like a compact prompt still has to grow once its
/// text field focuses and the keyboard would otherwise cover it, which shows
/// up as a visible two-step "open, then pop up further" animation. Alerts
/// reposition for the keyboard as a single system animation, avoiding that.
private struct RouteNameAlertModifier: ViewModifier {
    let title: LocalizedStringKey
    @Binding var isPresented: Bool
    let initialName: String
    let onCommit: (String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { onCommit(name) }
            }
            .onChange(of: isPresented) { _, presented in
                if presented { name = initialName }
            }
    }
}

/// Same alert, but driven by an optional identifiable item (e.g. renaming a
/// specific row from a list) rather than a plain `Bool`.
private struct RouteNameAlertItemModifier<Item: Identifiable>: ViewModifier {
    let title: LocalizedStringKey
    @Binding var item: Item?
    let initialName: (Item) -> String
    let onCommit: (Item, String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(
                title,
                isPresented: Binding(
                    get: { item != nil },
                    set: { presented in if !presented { item = nil } }
                ),
                presenting: item
            ) { item in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { onCommit(item, name) }
            }
            .onChange(of: item?.id) { _, _ in
                if let item { name = initialName(item) }
            }
    }
}

extension View {
    func routeNameAlert(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        initialName: String,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        modifier(RouteNameAlertModifier(title: title, isPresented: isPresented, initialName: initialName, onCommit: onCommit))
    }

    func routeNameAlert<Item: Identifiable>(
        _ title: LocalizedStringKey,
        item: Binding<Item?>,
        initialName: @escaping (Item) -> String,
        onCommit: @escaping (Item, String) -> Void
    ) -> some View {
        modifier(RouteNameAlertItemModifier(title: title, item: item, initialName: initialName, onCommit: onCommit))
    }
}
