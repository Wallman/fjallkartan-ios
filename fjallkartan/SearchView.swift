import CoreLocation
import SwiftUI

struct SearchView: View {
    @Binding var isPresented: Bool
    let onSelect: (CLLocationCoordinate2D) -> Void

    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private let service = PlaceSearchService()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: isLoading)
                TextField("Search places in Norway…", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit { scheduleSearch(query, delay: .zero) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        searchTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Cancel") {
                    isPresented = false
                }
                .font(.system(size: 15))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { result in
                            Button {
                                onSelect(result.coordinate)
                                isPresented = false
                            } label: {
                                ResultRow(result: result)
                            }
                            .buttonStyle(.plain)
                            if result.id != results.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { isFocused = true }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    private func scheduleSearch(_ text: String, delay: Duration = .milliseconds(300)) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        searchTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            isLoading = true
            do {
                let found = try await service.search(query: trimmed)
                guard !Task.isCancelled else { return }
                results = found
            } catch {}
            isLoading = false
        }
    }
}

private struct ResultRow: View {
    let result: PlaceResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: result.placeType))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Text([result.placeType, result.municipality]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func iconName(for placeType: String) -> String {
        switch placeType.lowercased() {
        case "by", "tettsted", "bydel": return "building.2"
        case "fjell", "fjelltopp": return "mountain.2"
        case "elv", "bekk": return "water.waves"
        case "innsjø", "vann", "tjern": return "drop"
        default: return "mappin"
        }
    }
}
