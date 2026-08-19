import SwiftUI

struct AboutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
            .font(.system(size: 22))
            .foregroundStyle(Color.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .environment(\.colorScheme, .light)
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingTileMetrics = false
    @State private var isShowingGuide = false
    @State private var isShowingMapLibrePOC = false

    private static let privacyPolicyURL = URL(string: "https://wallman.github.io/fjallkartan-ios/privacy.html")!
    private static let supportURL = URL(string: "https://wallman.github.io/fjallkartan-ios/support.html")!
    private static let kartverketURL = URL(string: "https://www.kartverket.no/")!
    private static let lantmaterietURL = URL(string: "https://www.lantmateriet.se/")!
    private static let nveURL = URL(string: "https://www.nve.no/")!

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Copyright") {
                    ExternalLink(title: "©Kartverket", url: Self.kartverketURL)
                    ExternalLink(title: "©Lantmäteriet", url: Self.lantmaterietURL)
                    ExternalLink(title: "©NVE", url: Self.nveURL)
                }

                Section {
                    Button {
                        isShowingGuide = true
                    } label: {
                        LabeledContent {
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("How to use the app")
                        }
                    }
                    Link(destination: Self.supportURL) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("Support")
                        }
                    }
                    Link(destination: Self.privacyPolicyURL) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("Privacy Policy")
                        }
                    }
                    LabeledContent("Version", value: appVersion)
                        .contentShape(Rectangle())
                        // Undiscoverable on purpose
                        .onLongPressGesture { isShowingTileMetrics = true }
                }

                // POC only — remove once the MapLibre comparison is done.
                Section {
                    Button("MapLibre POC") { isShowingMapLibrePOC = true }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingTileMetrics) {
                DebugSheet()
            }
            .sheet(isPresented: $isShowingGuide) {
                OnboardingSheet()
            }
            .fullScreenCover(isPresented: $isShowingMapLibrePOC) {
                MapLibrePOCView()
            }
        }
        .presentationDetents([.large])
    }
}

private struct ExternalLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            LabeledContent {
                Image(systemName: "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } label: {
                Text(verbatim: title)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

#Preview {
    AboutSheet()
}
