import SwiftUI

/// Names a route, both when saving a fresh measurement and when renaming a
/// saved one. Cancel never commits, so an accidental bookmark tap saves nothing.
struct RouteNameSheet: View {
    let title: LocalizedStringKey
    let initialName: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(title: LocalizedStringKey,
         initialName: String,
         onCommit: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                    if !name.isEmpty {
                        Button {
                            name = ""
                            isNameFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                }
            }
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .onAppear { isNameFocused = true }
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}
