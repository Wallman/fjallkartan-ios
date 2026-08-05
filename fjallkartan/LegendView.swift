import PDFKit
import SwiftUI

enum LegendCountry: String, CaseIterable, Identifiable {
    case sweden
    case norway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .norway: "Norge"
        case .sweden: "Sverige"
        }
    }

    var resourceName: String {
        switch self {
        case .norway: "legend_no"
        case .sweden: "legend_se"
        }
    }
}

struct LegendSheet: View {
    @State private var country: LegendCountry = .sweden
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = Bundle.main.url(forResource: country.resourceName, withExtension: "pdf") {
                    PDFKitView(url: url)
                } else {
                    ContentUnavailableView("Legend not found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle("Teckenförklaring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Land", selection: $country) {
                        ForEach(LegendCountry.allCases) { country in
                            Text(country.title).tag(country)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { dismiss() }
                }
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

#Preview {
    LegendSheet()
}
