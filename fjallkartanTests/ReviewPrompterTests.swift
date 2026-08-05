import Foundation
import Testing

@testable import fjallkartan

@MainActor
struct ReviewPrompterTests {
    /// Mutable clock so background gaps and the inter-prompt floor can be
    /// driven without waiting.
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { date += seconds }
    }

    /// Isolated defaults so tests never touch the real app's suite.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "review-tests-\(UUID().uuidString)")!
    }

    private func makePrompter(defaults: UserDefaults,
                              version: String = "1.0",
                              clock: Clock) -> ReviewPrompter {
        ReviewPrompter(defaults: defaults, currentVersion: version, now: { clock.date })
    }

    /// Simulates `count` separate app opens, each in a fresh process.
    private func openApp(times count: Int, defaults: UserDefaults, version: String = "1.0", clock: Clock) {
        for _ in 0..<count {
            makePrompter(defaults: defaults, version: version, clock: clock).noteBecameActive()
        }
    }

    // MARK: - The two conditions

    @Test func downloadAloneIsNotEnough() {
        let clock = Clock()
        let prompter = makePrompter(defaults: makeDefaults(), clock: clock)
        prompter.noteBecameActive() // first open only
        prompter.recordSuccessfulRegionDownload()
        #expect(!prompter.isEligible)
        #expect(prompter.pendingToken == 0)
    }

    @Test func appOpensAloneAreNotEnough() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens + 5, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        #expect(!prompter.isEligible)
        #expect(prompter.pendingToken == 0)
    }

    @Test func oneOrTwoMeasurementsAreNotEnough() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        for _ in 0..<(ReviewPrompter.requiredMeasurements - 1) {
            prompter.recordCompletedMeasurement()
        }
        #expect(!prompter.isEligible)
        #expect(prompter.pendingToken == 0)
    }

    @Test func becomesPendingOnThirdMeasurement() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        for _ in 0..<ReviewPrompter.requiredMeasurements {
            prompter.recordCompletedMeasurement()
        }
        #expect(prompter.isEligible)
        #expect(prompter.pendingToken == 1)
        #expect(prompter.consumePendingPrompt())
    }

    /// Measurements made before the app-open threshold still count towards it.
    @Test func measurementsAccumulateAcrossLaunches() {
        let clock = Clock()
        let defaults = makeDefaults()

        let early = makePrompter(defaults: defaults, clock: clock)
        early.noteBecameActive()
        for _ in 0..<ReviewPrompter.requiredMeasurements {
            early.recordCompletedMeasurement()
        }
        #expect(early.pendingToken == 0) // not enough opens yet

        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)
        let later = makePrompter(defaults: defaults, clock: clock)
        #expect(later.completedMeasurementCount == ReviewPrompter.requiredMeasurements)
        later.recordCompletedMeasurement()
        #expect(later.pendingToken == 1)
    }

    @Test func becomesPendingOnDownloadAfterEnoughOpens() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        prompter.recordSuccessfulRegionDownload()
        #expect(prompter.isEligible)
        #expect(prompter.pendingToken == 1)
        #expect(prompter.consumePendingPrompt())
    }

    /// Apple asks that a review request never appear simply because the app
    /// launched, so reaching the open threshold must not arm a prompt on its
    /// own — even when a download already succeeded earlier.
    @Test func reachingOpenThresholdDoesNotArmAPromptOnItsOwn() {
        let clock = Clock()
        let defaults = makeDefaults()

        let first = makePrompter(defaults: defaults, clock: clock)
        first.noteBecameActive()
        first.recordSuccessfulRegionDownload()

        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)
        let later = makePrompter(defaults: defaults, clock: clock)
        later.noteBecameActive()
        #expect(later.isEligible) // conditions met...
        #expect(later.pendingToken == 0) // ...but nothing is armed until the next success

        later.recordSuccessfulRegionDownload()
        #expect(later.pendingToken == 1)
    }

    // MARK: - Counting app opens

    @Test func briefBackgroundingDoesNotCountAsANewOpen() {
        let clock = Clock()
        let prompter = makePrompter(defaults: makeDefaults(), clock: clock)
        prompter.noteBecameActive() // cold launch
        #expect(prompter.appOpenCount == 1)

        for _ in 0..<10 {
            prompter.noteEnteredBackground()
            clock.advance(60) // a minute away
            prompter.noteBecameActive()
        }
        #expect(prompter.appOpenCount == 1)
    }

    @Test func returningAfterALongGapCountsAsANewOpen() {
        let clock = Clock()
        let prompter = makePrompter(defaults: makeDefaults(), clock: clock)
        prompter.noteBecameActive()

        for _ in 1..<ReviewPrompter.requiredAppOpens {
            prompter.noteEnteredBackground()
            clock.advance(ReviewPrompter.backgroundGapForNewOpen + 1)
            prompter.noteBecameActive()
        }
        #expect(prompter.appOpenCount == ReviewPrompter.requiredAppOpens)

        prompter.recordSuccessfulRegionDownload()
        #expect(prompter.pendingToken == 1)
    }

    /// Going active without having been backgrounded (e.g. dismissing control
    /// centre) must not count.
    @Test func becomingActiveWithoutBackgroundingDoesNotCount() {
        let clock = Clock()
        let prompter = makePrompter(defaults: makeDefaults(), clock: clock)
        prompter.noteBecameActive()
        clock.advance(ReviewPrompter.backgroundGapForNewOpen * 5)
        prompter.noteBecameActive()
        prompter.noteBecameActive()
        #expect(prompter.appOpenCount == 1)
    }

    @Test func countersPersistAcrossLaunches() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: 2, defaults: defaults, clock: clock)
        makePrompter(defaults: defaults, clock: clock).recordSuccessfulRegionDownload()

        let fresh = makePrompter(defaults: defaults, clock: clock)
        #expect(fresh.appOpenCount == 2)
        #expect(fresh.successfulDownloadCount == 1)
    }

    // MARK: - Throttling

    @Test func promptsOnlyOncePerVersion() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        prompter.recordSuccessfulRegionDownload()
        #expect(prompter.consumePendingPrompt())

        // Same version, more successful downloads: still no second prompt.
        let again = makePrompter(defaults: defaults, clock: clock)
        again.recordSuccessfulRegionDownload()
        #expect(again.pendingToken == 0)
        #expect(!again.consumePendingPrompt())

        // A later version is allowed again, once past the time floor.
        clock.advance(ReviewPrompter.minimumDaysBetweenPrompts * 86_400 + 60)
        let next = makePrompter(defaults: defaults, version: "1.1", clock: clock)
        next.recordSuccessfulRegionDownload()
        #expect(next.consumePendingPrompt())
    }

    @Test func respectsMinimumIntervalAcrossVersions() {
        let clock = Clock()
        let defaults = makeDefaults()
        openApp(times: ReviewPrompter.requiredAppOpens, defaults: defaults, clock: clock)

        let prompter = makePrompter(defaults: defaults, clock: clock)
        prompter.recordSuccessfulRegionDownload()
        #expect(prompter.consumePendingPrompt())

        clock.advance(86_400)
        let next = makePrompter(defaults: defaults, version: "1.1", clock: clock)
        next.recordSuccessfulRegionDownload()
        #expect(!next.isEligible)
        #expect(!next.consumePendingPrompt())
    }
}
