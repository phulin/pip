import XCTest
@testable import Pip
final class FeedTimerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    func runningFeed() -> CareActivity {
        CareActivity(babyId: "baby", kind: .breast, startedAt: start.timeIntervalSince1970 * 1000, segmentStartedAt: start.timeIntervalSince1970 * 1000)
    }
    func testSwitchAccumulatesEachSideWithoutResettingTotal() {
        var feed = runningFeed()
        feed.switchSide(at: start.addingTimeInterval(60))
        XCTAssertEqual(feed.side, .right)
        XCTAssertEqual(feed.leftSeconds, 60)
        XCTAssertEqual(feed.total(at: start.addingTimeInterval(90)), 90)
        XCTAssertEqual(feed.seconds(.right, at: start.addingTimeInterval(90)), 30)
    }
    func testPauseExcludesTimeAndSwitchWhilePausedDoesNotResume() {
        var feed = runningFeed()
        feed.togglePause(at: start.addingTimeInterval(40))
        feed.switchSide(at: start.addingTimeInterval(100))
        XCTAssertTrue(feed.paused)
        XCTAssertNil(feed.segmentStartedAt)
        XCTAssertEqual(feed.total(at: start.addingTimeInterval(200)), 40)
        feed.togglePause(at: start.addingTimeInterval(200))
        feed.finish(at: start.addingTimeInterval(230))
        XCTAssertEqual(feed.leftSeconds, 40)
        XCTAssertEqual(feed.rightSeconds, 30)
        XCTAssertFalse(feed.isRunning)
        XCTAssertEqual(feed.total(at: start.addingTimeInterval(1000)), 70)
    }
    func testPersistenceRestoresRunningTimerAndMutationIdentity() throws {
        let feed = runningFeed()
        let restored = try JSONDecoder().decode(CareActivity.self, from: JSONEncoder().encode(feed))
        XCTAssertEqual(restored, feed)
        XCTAssertEqual(restored.total(at: start.addingTimeInterval(3600)), 3600)
    }
    func testPumpAndBottleTimersSurviveRelaunchAndPause() throws {
        for kind in [ActivityKind.pump, .bottle] {
            var activity = runningFeed()
            activity.kind = kind
            activity.volumeML = 60
            XCTAssertTrue(activity.isRunning)
            activity.togglePause(at: start.addingTimeInterval(45))
            var restored = try JSONDecoder().decode(CareActivity.self, from: JSONEncoder().encode(activity))
            XCTAssertEqual(restored.total(at: start.addingTimeInterval(90)), 45)
            XCTAssertEqual(restored.volumeML, 60)
            restored.togglePause(at: start.addingTimeInterval(100))
            restored.finish(at: start.addingTimeInterval(130))
            XCTAssertEqual(restored.total(at: start.addingTimeInterval(200)), 75)
            XCTAssertFalse(restored.isRunning)
        }
    }
    func testBackwardClockDoesNotCreateNegativeDuration() {
        XCTAssertEqual(runningFeed().total(at: start.addingTimeInterval(-100)), 0)
    }
    func testTargetCommandsDoNotDoubleToggleAndSurvivePersistence() throws {
        let command = ActivityCommand(activityId: "feed", occurredAt: start.addingTimeInterval(30).timeIntervalSince1970 * 1000, side: .right)
        let restored = try JSONDecoder().decode(ActivityCommand.self, from: JSONEncoder().encode(command))
        let once = restored.applying(to: runningFeed())
        let twice = restored.applying(to: once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.side, .right)
        XCTAssertEqual(twice.leftSeconds, 30)
        let pause = ActivityCommand(activityId: "feed", occurredAt: start.addingTimeInterval(60).timeIntervalSince1970 * 1000, paused: true)
        let paused = pause.applying(to: twice)
        XCTAssertEqual(pause.applying(to: paused), paused)
        XCTAssertEqual(paused.total(at: start.addingTimeInterval(100)), 60)
    }
    func testLateOfflineCommandsNeverReopenFinishedFeed() {
        var a = runningFeed(); a.finish(at: start.addingTimeInterval(60))
        let resume = ActivityCommand(activityId: a.id, paused: false)
        XCTAssertEqual(resume.applying(to: a), a)
    }

    func testIndependentControlsMergeWhenTheyArriveOutOfOrder() {
        let side = ActivityCommand(activityId: "feed", occurredAt: 1040000, side: .right)
        let pause = ActivityCommand(activityId: "feed", occurredAt: 1030000, paused: true)
        let a = pause.applying(to: side.applying(to: runningFeed()))
        XCTAssertEqual(a.side, .right); XCTAssertTrue(a.paused)
        let stale = ActivityCommand(activityId: "feed", occurredAt: 1020000, side: .left, paused: false)
        XCTAssertEqual(stale.applying(to: a), a)
        XCTAssertEqual(a.total(at: start.addingTimeInterval(100)), 40)
    }

}
