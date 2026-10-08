import XCTest
@testable import Codeg

final class LivenessTrackerTests: XCTestCase {
    func testSilentConnectionTimesOutAt45SecondsWithoutPongCallback() {
        var now: TimeInterval = 1_000
        var tracker = LivenessTracker(clock: { now })
        for elapsed in [0.0, 15, 30, 44.999] {
            now = 1_000 + elapsed
            XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 0))
        }
        now = 1_045
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 0))
    }

    func testPongRestartsDeadline() {
        var now: TimeInterval = 0
        var tracker = LivenessTracker(clock: { now })
        now = 40
        tracker.recordPong()
        now = 84.999
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 0))
        now = 85
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 0))
    }

    func testAnyMessageRestartsDeadlineWithoutAPong() {
        var now: TimeInterval = 0
        var tracker = LivenessTracker(clock: { now })
        now = 44
        tracker.recordMessage()
        now = 88.999
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 0))
        now = 89
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 0))
    }

    func testTricklingFrameStaysAliveBeyond45SecondsWithoutCompleteMessage() {
        var now: TimeInterval = 0
        var tracker = LivenessTracker(clock: { now })
        for tick in 1...8 {
            now = Double(tick) * 30
            XCTAssertFalse(tracker.hasTimedOut(bytesReceived: Int64(tick * 1_024)))
        }
        now = 284.999
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 8_192))
        now = 285
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 8_192))
    }

    func testUnchangedOrDecreasingByteCountDoesNotRefreshDeadline() {
        var now: TimeInterval = 0
        var tracker = LivenessTracker(clock: { now })
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 1_024))
        now = 30
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 1_024))
        now = 44
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 512))
        now = 45
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 1_024))
    }

    func testMostRecentActivityWinsAcrossPongMessageAndBytes() {
        var now: TimeInterval = 0
        var tracker = LivenessTracker(clock: { now })
        now = 30
        tracker.recordPong()
        now = 60
        tracker.recordMessage()
        now = 90
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 512))
        now = 134.999
        XCTAssertFalse(tracker.hasTimedOut(bytesReceived: 512))
        now = 135
        XCTAssertTrue(tracker.hasTimedOut(bytesReceived: 512))
    }
}
