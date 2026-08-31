import SwiftUI

/// Full-screen, non-dismissable overlay shown when the running app is older
/// than remote settings' `minAppVersion`. Covers the map entirely so no
/// gesture reaches it underneath.
struct ForceUpdateView: View {
    var onUpdate: () -> Void = {
        UIApplication.shared.open(ForceUpdateGate.appStoreURL)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Update required")
                    .font(.title2.bold())
                Text("A new version of Fjällkartan is required to continue. Please update the app from the App Store.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                Button(action: onUpdate) {
                    Text("Update Now")
                        .font(.headline)
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .transition(.opacity)
    }
}

#Preview {
    ForceUpdateView()
}
