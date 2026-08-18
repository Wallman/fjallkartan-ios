import SwiftUI

/// A single line of fine print under a page, used for the interactions that a
/// user is unlikely to find on their own (callout buttons, gestures, undo).
struct OnboardingNote: Identifiable {
    let symbol: String
    let text: LocalizedStringResource

    var id: String { symbol }
}

struct OnboardingPage: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    var notes: [OnboardingNote] = []
}

extension OnboardingPage {
    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: "search",
            symbol: "magnifyingglass",
            title: "Find a place",
            message: "Search Norwegian and Swedish place names, including local alternatives.",
            notes: [
                OnboardingNote(symbol: "bookmark", text: "Save the result as a pin"),
            ]
        ),
        OnboardingPage(
            id: "measure",
            symbol: "ruler",
            title: "Measure a route",
            message: "Tap the ruler, then drag to trace your route.",
            notes: [
                OnboardingNote(symbol: "hand.draw", text: "One finger draws"),
                OnboardingNote(symbol: "hand.point.up.left", text: "Two fingers move and zoom the map"),
                OnboardingNote(symbol: "scribble", text: "Lift your finger and draw again to continue"),
                OnboardingNote(symbol: "arrow.uturn.backward", text: "Undo removes the last stroke"),
                OnboardingNote(symbol: "mountain.2", text: "Tap the distance readout to open the terrain profile."),
                OnboardingNote(symbol: "bookmark", text: "Save the route for later"),
            ]
        ),
        OnboardingPage(
            id: "pins",
            symbol: "mappin.and.ellipse",
            title: "Mark a spot",
            message: "Press and hold the map to drop a pin. Tap a pin to rename or delete it."
        ),
        OnboardingPage(
            id: "slope",
            symbol: "triangle.righthalf.filled",
            title: "Steepness",
            message: "Shade the terrain by slope angle to spot steep ground."
        ),
        OnboardingPage(
            id: "offline",
            symbol: "arrow.down.circle",
            title: "Offline mode",
            message: "Tap download and frame the area. The dashed box is what gets saved."
        ),
        OnboardingPage(
            id: "ready",
            symbol: "checkmark.circle",
            title: "You're ready",
            message: "Open this guide again from the info button."
        ),
    ]
}

/// Paged get-started guide, shown once on first launch and reachable from
/// `AboutSheet` afterwards.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0

    private let pages = OnboardingPage.all

    private var isLastPage: Bool { selection >= pages.count - 1 }

    private var stepCount: Int { max(pages.count - 1, 1) }

    /// The closing page keeps the last dot lit rather than clearing them all.
    private var currentStep: Int { min(selection, stepCount - 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    // Kept in the layout on the last page so the pages don't
                    // shift when it goes away.
                    .opacity(isLastPage ? 0 : 1)
                    .disabled(isLastPage)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Own dots rather than the built-in ones, so the closing page —
            // which is a sign-off, not a step — has no indicator at all.
            // Kept in the layout so the pages don't shift on the way there.
            HStack(spacing: 8) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? Color.orange : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .opacity(isLastPage ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: selection)
            .padding(.bottom, 20)

            Button {
                if isLastPage {
                    dismiss()
                } else {
                    withAnimation { selection += 1 }
                }
            } label: {
                Text(isLastPage ? "Done" : "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        // Scrollable so a page with many notes still fits at large text sizes.
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Image(systemName: page.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 96, height: 96)
                .background(Color.orange.opacity(0.12), in: Circle())

            Text(page.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(page.message)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !page.notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(page.notes) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: note.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .frame(width: 22)
                            Text(note.text)
                                .font(.system(size: 14))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }
}

#Preview {
    OnboardingSheet()
}
