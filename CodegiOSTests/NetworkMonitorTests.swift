import Network
import XCTest
@testable import Codeg

final class NetworkMonitorTests: XCTestCase {
    private typealias Snapshot = NetworkMonitor.Snapshot

    func testInitialSnapshotDoesNotCloseANewConnection() {
        XCTAssertFalse(NetworkMonitor.isMeaningfulChange(
            old: nil, new: Snapshot(status: .satisfied, primaryInterface: .wifi)
        ))
    }

    func testConnectivityRestoredIsMeaningfulEvenOnSameInterface() {
        XCTAssertTrue(NetworkMonitor.isMeaningfulChange(
            old: Snapshot(status: .unsatisfied, primaryInterface: .wifi),
            new: Snapshot(status: .satisfied, primaryInterface: .wifi)
        ))
    }

    func testSatisfiedInterfaceChangesAreMeaningful() {
        let changes: [(NWInterface.InterfaceType?, NWInterface.InterfaceType?)] = [
            (.wifi, .cellular), (.cellular, .wifi), (.wifi, .wiredEthernet),
            (.wifi, nil), (nil, .wifi),
        ]
        for (old, new) in changes {
            XCTAssertTrue(NetworkMonitor.isMeaningfulChange(
                old: Snapshot(status: .satisfied, primaryInterface: old),
                new: Snapshot(status: .satisfied, primaryInterface: new)
            ))
        }
    }

    func testCostAndConstraintChangesAloneDoNotCloseConnections() {
        let old = Snapshot(status: .satisfied, primaryInterface: .wifi)
        var new = old
        new.isExpensive = true
        new.isConstrained = true
        XCTAssertFalse(NetworkMonitor.isMeaningfulChange(old: old, new: old))
        XCTAssertFalse(NetworkMonitor.isMeaningfulChange(old: old, new: new))
    }

    func testUnsatisfiedAndRequiresConnectionPathsDoNotTriggerReconnects() {
        let changes: [(NWPath.Status, NWPath.Status)] = [
            (.satisfied, .unsatisfied), (.unsatisfied, .unsatisfied),
            (.satisfied, .requiresConnection), (.requiresConnection, .satisfied),
        ]
        for (old, new) in changes {
            XCTAssertFalse(NetworkMonitor.isMeaningfulChange(
                old: Snapshot(status: old, primaryInterface: .wifi),
                new: Snapshot(status: new, primaryInterface: .cellular)
            ))
        }
    }
}
