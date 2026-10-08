import XCTest
@testable import Codeg

final class EndpointSelectorTests: XCTestCase {
    func testDecisionTable() {
        let rows: [(Bool, Bool, Bool, EndpointSelector.Endpoint?)] = [
            (true, true, true, .primary), (true, true, false, .primary),
            (true, false, true, .secondary), (true, false, false, nil),
            (false, true, true, .secondary), (false, true, false, .primary),
            (false, false, true, .secondary), (false, false, false, nil),
        ]
        for (wifi, primary, secondary, expected) in rows {
            XCTAssertEqual(EndpointSelector.decide(onWiFi: wifi, primaryHealthy: primary, secondaryHealthy: secondary), expected)
        }
    }

    func testChoiceStaysCachedUntilTriggerAndFailuresReset() {
        var selector = EndpointSelector()
        XCTAssertTrue(selector.needsProbe)
        selector.accept(onWiFi: true, primaryHealthy: true, secondaryHealthy: true)
        XCTAssertEqual(selector.choice, .primary)
        XCTAssertFalse(selector.needsProbe)
        selector.recordFailure()
        XCTAssertFalse(selector.needsProbe)
        selector.recordSuccess()
        selector.recordFailure()
        XCTAssertFalse(selector.needsProbe)
        selector.recordFailure()
        XCTAssertTrue(selector.needsProbe)
        selector.accept(onWiFi: false, primaryHealthy: true, secondaryHealthy: true)
        XCTAssertEqual(selector.choice, .secondary)
        selector.trigger()
        XCTAssertTrue(selector.needsProbe)
        selector.accept(onWiFi: true, primaryHealthy: false, secondaryHealthy: false)
        XCTAssertEqual(selector.choice, .secondary, "Both down retains choice rather than oscillating")
        XCTAssertFalse(selector.needsProbe)
    }
}
