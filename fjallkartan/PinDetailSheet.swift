import SwiftUI

struct PinDetailSheet: View {
    let pin: SavedPin
    let onSave: (SavedPin) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var notes: String

    init(pin: SavedPin, onSave: @escaping (SavedPin) -> Void, onDelete: @escaping () -> Void) {
        self.pin = pin
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: pin.name ?? "")
        _notes = State(initialValue: pin.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        .onChange(of: name) { save() }
        .onChange(of: notes) { save() }
    }

    private func save() {
        var updated = pin
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmedName.isEmpty ? nil : trimmedName
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        guard updated != pin else { return }
        onSave(updated)
    }
}
