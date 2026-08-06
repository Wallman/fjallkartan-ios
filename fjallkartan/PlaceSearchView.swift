import CoreLocation
import Observation
import SwiftUI

@Observable
final class PlaceSearchModel {
var query: String = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }
    private(set) var results: [PlaceResult] = []
    private(set) var isSearching = false

    var selection: PlaceResult?
    static let minimumQueryLength = 2

    @ObservationIgnored private lazy var search = PlaceSearch()
    @ObservationIgnored private let queue = DispatchQueue(label: "PlaceSearch", qos: .userInitiated)
    @ObservationIgnored private var pendingWork: DispatchWorkItem?
    @ObservationIgnored private var generation = 0

    func clear() {
        pendingWork?.cancel()
        query = ""
        results = []
        isSearching = false
    }

    private func scheduleSearch() {
        pendingWork?.cancel()
        generation &+= 1

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= Self.minimumQueryLength, let search else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            let found = search.search(trimmed)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.results = found
                self.isSearching = false
            }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

struct PlaceSearchSheet: View {
    @Bindable var model: PlaceSearchModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            resultsList
                .navigationTitle("Search places")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .onAppear { isFieldFocused = true }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(model.results) { result in
                Button {
                    model.selection = result
                    dismiss()
                } label: {
                    PlaceRow(result: result)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Name of mountain, lake, place …", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFieldFocused)
            if !model.query.isEmpty {
                Button {
                    model.clear()
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct PlaceRow: View {
    let result: PlaceResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.kind.symbolName)
                .font(.system(size: 15))
                .frame(width: 26)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 16))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(verbatim: result.country == .norway ? "NO" : "SE")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let alias = result.matchedAlias {
                    Text("also \(alias)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
