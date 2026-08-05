import Foundation
import Observation

/// Decides when it is polite to ask for an App Store review.
///
/// Follows Apple's guidance for `RequestReviewAction`: ask at the end of
/// something the user successfully completed, never straight after launch,
/// and never as the direct result of a tap.
///
/// Two conditions must line up:
/// - *engagement*: at least `requiredAppOpens` app opens, so a first-run user
///   who is still evaluating the app is never asked;
/// - *success*: either an offline region download that reached `.completed`,
///   or `requiredMeasurements` finished distance measurements — the two things
///   in this app a user does deliberately and finishes with a result in hand.
///
/// Only a success moment sets `pendingToken`; app opens merely accrue in the
/// background. `ContentView` turns a pending token into the actual request
/// once nothing is covering the map.
@MainActor
@Observable
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    static let requiredAppOpens = 3
    static let requiredMeasurements = 3
    static let minimumMeasurementMeters = 500.0

    /// How long the app must have been backgrounded for the next foreground to count as a new open
    static let backgroundGapForNewOpen: TimeInterval = 30 * 60 // 30m

    static let minimumDaysBetweenPrompts = 120.0

    /// Bumped when a prompt becomes due. Views observe this to run the request at a quiet moment.
    private(set) var pendingToken = 0

    private let defaults: UserDefaults
    private let currentVersion: String
    private let now: () -> Date

    private var hasCountedColdLaunch = false
    private var backgroundedAt: Date?

    private enum Key {
        static let appOpens = "review.appOpens"
        static let successes = "review.successfulRegionDownloads"
        static let measurements = "review.completedMeasurements"
        static let promptedVersion = "review.lastPromptedVersion"
        static let promptedDate = "review.lastPromptedDate"
    }

    /// Dependencies are injectable so tests can drive the clock and version
    /// without touching `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard,
         currentVersion: String = ReviewPrompter.bundleVersion,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
    }

    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private(set) var appOpenCount: Int {
        get { defaults.integer(forKey: Key.appOpens) }
        set { defaults.set(newValue, forKey: Key.appOpens) }
    }

    private(set) var successfulDownloadCount: Int {
        get { defaults.integer(forKey: Key.successes) }
        set { defaults.set(newValue, forKey: Key.successes) }
    }

    private(set) var completedMeasurementCount: Int {
        get { defaults.integer(forKey: Key.measurements) }
        set { defaults.set(newValue, forKey: Key.measurements) }
    }

    private var lastPromptedVersion: String? {
        get { defaults.string(forKey: Key.promptedVersion) }
        set { defaults.set(newValue, forKey: Key.promptedVersion) }
    }

    private var lastPromptedDate: Date? {
        get {
            let seconds = defaults.double(forKey: Key.promptedDate)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.promptedDate) }
    }

    /// Whether a prompt is warranted right now.
    var isEligible: Bool {
        guard appOpenCount >= Self.requiredAppOpens, hasSucceededEnough else { return false }
        // One prompt per version at most: a user who declined on this build
        // should not be asked again on it.
        guard lastPromptedVersion != currentVersion else { return false }
        if let last = lastPromptedDate,
           now().timeIntervalSince(last) < Self.minimumDaysBetweenPrompts * 86_400 {
            return false
        }
        return true
    }

    /// Either success path on its own is enough.
    private var hasSucceededEnough: Bool {
        successfulDownloadCount >= 1 || completedMeasurementCount >= Self.requiredMeasurements
    }

    // MARK: - Signals

    /// Call once per offline region download that reached `.completed`.
    /// Cancelled and failed downloads must not call this.
    func recordSuccessfulRegionDownload() {
        successfulDownloadCount += 1
        if isEligible { pendingToken += 1 }
    }

    /// Call when the user finishes measuring a route of at least
    /// `minimumMeasurementMeters`.
    func recordCompletedMeasurement() {
        completedMeasurementCount += 1
        if isEligible { pendingToken += 1 }
    }

    /// Call when the scene becomes active. Counts an open on the cold launch,
    /// and thereafter only when the app has been in the background long enough.
    ///
    /// This deliberately never sets `pendingToken`: Apple asks that a review
    /// request not appear just because the app was launched.
    func noteBecameActive() {
        if !hasCountedColdLaunch {
            hasCountedColdLaunch = true
            appOpenCount += 1
            return
        }
        defer { backgroundedAt = nil }
        guard let backgroundedAt,
              now().timeIntervalSince(backgroundedAt) >= Self.backgroundGapForNewOpen else { return }
        appOpenCount += 1
    }

    /// Call when the scene enters the background. Transitions to merely
    /// `.inactive` (control centre, a call banner) deliberately don't count.
    func noteEnteredBackground() {
        backgroundedAt = now()
    }

    /// Marks a due prompt as spent. Returns `false` when nothing is due, in
    /// which case the caller must not show the system prompt.
    ///
    /// Counters are left alone; the per-version and 120-day rules are what
    /// keep a long-term user from being asked repeatedly.
    func consumePendingPrompt() -> Bool {
        guard isEligible else { return false }
        lastPromptedVersion = currentVersion
        lastPromptedDate = now()
        return true
    }
}
