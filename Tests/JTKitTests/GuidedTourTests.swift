import Foundation
import Testing
@testable import JTKit

@Suite("Guided tour")
@MainActor
struct GuidedTourTests {
    private let key = "hasSeenGuidedTour"

    /// Fresh, empty defaults per test.
    private func makeDefaults() throws -> UserDefaults {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeTour(defaults: UserDefaults) -> TourState<String> {
        TourState(
            steps: [
                TourStep(title: "Welcome", text: "Hello"),
                TourStep(title: "Sidebar", text: "Here", anchorID: "sidebar"),
                TourStep(title: "Toolbar", text: "Up there", pointsAtToolbar: true),
            ],
            firstLaunchDefaultsKey: key,
            defaults: defaults
        )
    }

    @Test func walksForwardAndBack() throws {
        let tour = makeTour(defaults: try makeDefaults())
        #expect(tour.currentStep == nil, "Not running until started")
        tour.start()
        #expect(tour.currentStep?.title == "Welcome")
        tour.back()
        #expect(tour.index == 0, "Back on the first step stays there")
        tour.next()
        #expect(tour.currentStep?.anchorID == "sidebar")
        tour.next()
        #expect(tour.currentStep?.pointsAtToolbar == true)
        tour.back()
        #expect(tour.currentStep?.title == "Sidebar")
    }

    @Test func nextOnTheLastStepEndsTheTour() throws {
        let tour = makeTour(defaults: try makeDefaults())
        tour.start()
        tour.next()
        tour.next()
        tour.next()
        #expect(tour.index == nil)
        #expect(tour.currentStep == nil)
    }

    @Test func skipEndsTheTour() throws {
        let tour = makeTour(defaults: try makeDefaults())
        tour.start()
        tour.next()
        tour.end()
        #expect(tour.currentStep == nil)
    }

    @Test func startsOnlyOnTheFirstLaunch() throws {
        let defaults = try makeDefaults()
        let first = makeTour(defaults: defaults)
        first.startOnFirstLaunch()
        #expect(first.index == 0)
        #expect(defaults.bool(forKey: key), "Marked seen as soon as it starts, so skipping counts")

        let relaunch = makeTour(defaults: defaults)
        relaunch.startOnFirstLaunch()
        #expect(relaunch.index == nil)

        relaunch.start()
        #expect(relaunch.index == 0, "Help › Guided Tour still replays it")
    }
}
