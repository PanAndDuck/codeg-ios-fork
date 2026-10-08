import Network
import XCTest
@testable import Codeg

final class WebSocketHealthMonitorTests: XCTestCase {
    func testMissingPongsDoNotStopTicksAndDeadlineClosesOnlyOnce() {
        let task = HeartbeatTask()
        let state = HealthTestState()
        let monitor = WebSocketHealthMonitor(task: task, clock: { state.now }) { state.close($0) }
        state.now = 15
        monitor.checkLiveness()
        state.now = 30
        monitor.checkLiveness()
        XCTAssertEqual(task.pings.count, 2)
        XCTAssertTrue(state.reasons.isEmpty)
        state.now = 45
        monitor.checkLiveness()
        state.now = 60
        monitor.checkLiveness()
        XCTAssertEqual(task.pings.count, 2)
        XCTAssertEqual(state.reasons, ["keepalive timeout"])
    }

    func testPongMessageAndByteProgressEachKeepTransportAlive() {
        let task = HeartbeatTask()
        let state = HealthTestState()
        let monitor = WebSocketHealthMonitor(task: task, clock: { state.now }) { state.close($0) }
        monitor.sendPing()
        state.now = 40
        task.pings.first?(nil)
        state.now = 60
        monitor.checkLiveness()
        state.now = 80
        monitor.recordMessage()
        state.now = 100
        monitor.checkLiveness()
        state.now = 120
        task.countOfBytesReceived = 1_024
        monitor.checkLiveness()
        state.now = 150
        monitor.checkLiveness()
        XCTAssertTrue(state.reasons.isEmpty)
        state.now = 165
        monitor.checkLiveness()
        XCTAssertEqual(state.reasons, ["keepalive timeout"])
    }

    func testMeaningfulPathChangeClosesOnlyOnce() {
        let state = HealthTestState()
        let monitor = WebSocketHealthMonitor(task: HeartbeatTask()) { state.close($0) }
        let wifi = NetworkMonitor.Snapshot(status: .satisfied, primaryInterface: .wifi)
        let cellular = NetworkMonitor.Snapshot(status: .satisfied, primaryInterface: .cellular)
        monitor.pathChanged(old: nil, new: wifi)
        monitor.pathChanged(old: wifi, new: wifi)
        XCTAssertTrue(state.reasons.isEmpty)
        monitor.pathChanged(old: wifi, new: cellular)
        monitor.pathChanged(old: cellular, new: wifi)
        XCTAssertEqual(state.reasons, ["network changed"])
    }

    func testStopIgnoresLatePongsErrorsAndPathChanges() {
        let task = HeartbeatTask()
        let state = HealthTestState()
        let monitor = WebSocketHealthMonitor(task: task, clock: { state.now }) { state.close($0) }
        monitor.start()
        monitor.sendPing()
        monitor.stop()
        monitor.stop()
        monitor.start()
        task.pings.first?(URLError(.networkConnectionLost))
        state.now = 90
        monitor.checkLiveness()
        monitor.sendPing()
        monitor.pathChanged(
            old: .init(status: .unsatisfied, primaryInterface: nil),
            new: .init(status: .satisfied, primaryInterface: .wifi)
        )
        XCTAssertEqual(task.pings.count, 1)
        XCTAssertTrue(state.reasons.isEmpty)
    }

    func testPingErrorCannotOverrideRecentMessageProgress() {
        let task = HeartbeatTask()
        let state = HealthTestState()
        let monitor = WebSocketHealthMonitor(task: task, clock: { state.now }) { state.close($0) }
        monitor.sendPing()
        state.now = 40
        monitor.recordMessage()
        task.pings.first?(URLError(.timedOut))
        state.now = 60
        monitor.checkLiveness()
        XCTAssertEqual(task.pings.count, 2)
        XCTAssertTrue(state.reasons.isEmpty)
        state.now = 85
        monitor.checkLiveness()
        XCTAssertEqual(state.reasons, ["keepalive timeout"])
    }

    func testTimerAndNetworkObservationDoNotRetainMonitor() {
        var monitor: WebSocketHealthMonitor? = WebSocketHealthMonitor(task: HeartbeatTask()) { _ in }
        let weakMonitor = { [weak monitor] in monitor }
        monitor?.start()
        monitor = nil
        XCTAssertNil(weakMonitor())
    }
}

private final class HeartbeatTask: WebSocketHeartbeatTask {
    var countOfBytesReceived: Int64 = 0
    var pings: [@Sendable (Error?) -> Void] = []

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pings.append(pongReceiveHandler)
    }
}

private final class HealthTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var closeReasons: [String] = []

    var now: TimeInterval {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }

    var reasons: [String] { lock.withLock { closeReasons } }
    func close(_ reason: String) { lock.withLock { closeReasons.append(reason) } }
}
