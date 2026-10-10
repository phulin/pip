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
    func testBackwardClockDoesNotCreateNegativeDuration() {
        XCTAssertEqual(runningFeed().total(at: start.addingTimeInterval(-100)), 0)
    }
}
