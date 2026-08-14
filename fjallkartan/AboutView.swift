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

    private static let privacyPolicyURL = URL(string: "https://wallman.github.io/fjallkartan-ios/privacy.html")!
    private static let kartverketURL = URL(string: "https://www.kartverket.no/")!
    private static let lantmaterietURL = URL(string: "https://www.lantmateriet.se/")!

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
                }

                Section {
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
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
