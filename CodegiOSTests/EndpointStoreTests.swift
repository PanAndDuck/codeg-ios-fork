import XCTest
import Network
@testable import Codeg

@MainActor
final class EndpointStoreTests: XCTestCase {
    private let wifi = NetworkMonitor.Snapshot(status: .satisfied, primaryInterface: .wifi)
    private let cellular = NetworkMonitor.Snapshot(status: .satisfied, primaryInterface: .cellular)

    func testNetworkSwitchCachesProbesAndKeepsEndpointPinsSeparate() async throws {
        let probes = ProbeRecorder()
        let suite = "I6-selector-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults) { endpoint, token, headers, timeout in
            await probes.check(endpoint, token: token, headers: headers, timeout: timeout)
        }
        let pin = String(repeating: "ab", count: 32)
        let headers = [HeaderPair(name: "CF-Access-Client-Secret", value: "fixture")]
        let profile = try XCTUnwrap(store.add(name: "Home", urlString: "http://lan.invalid:3090", token: "test",
                                              secondaryEndpoint: .init(urlString: "https://relay.invalid:18443", pinnedCertSHA256: pin), customHeaders: headers))
        defer { store.delete(profile) }
        let existingClient = try XCTUnwrap(store.client(for: profile))
        let identity = profile.connectionIdentity
        store.networkDidChange(old: nil, new: wifi)
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(store.endpointLabel(for: profile), "LAN")
        await store.prepareEndpoint(for: profile)
        var calls = await probes.calls
        XCTAssertEqual(calls.count, 2, "Cached choice must not probe on each read")
        let primary = try XCTUnwrap(calls.first { $0.endpoint.urlString.contains("lan.invalid") })
        let secondary = try XCTUnwrap(calls.first { $0.endpoint.urlString.contains("relay.invalid") })
        XCTAssertEqual(primary.timeout, 1.5)
        XCTAssertEqual(secondary.timeout, 5)
        XCTAssertNil(primary.endpoint.pinnedCertSHA256)
        XCTAssertEqual(secondary.endpoint.pinnedCertSHA256, pin)
        XCTAssertEqual(primary.headers, headers)
        XCTAssertEqual(secondary.headers, headers)

        store.networkDidChange(old: wifi, new: cellular)
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(store.endpointLabel(for: profile), "Relay")
        XCTAssertEqual(existingClient.baseURL.host, "relay.invalid")
        XCTAssertEqual(existingClient.transport.snapshot.sessions.pin, pin)
        XCTAssertEqual(store.servers.first?.connectionIdentity, identity)
        calls = await probes.calls
        XCTAssertEqual(calls.count, 4)
        store.networkDidChange(old: cellular, new: .init(status: .satisfied, primaryInterface: .cellular, isExpensive: true))
        await store.prepareEndpoint(for: profile)
        let unchangedCalls = await probes.calls
        XCTAssertEqual(unchangedCalls.count, 4)
    }

    func testRepeatedSocketFailuresTriggerProbeDespiteSuccessfulHTTP() async throws {
        let probes = ProbeRecorder()
        let suite = "I6-failures-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults) { endpoint, token, headers, timeout in
            await probes.check(endpoint, token: token, headers: headers, timeout: timeout)
        }
        let profile = try XCTUnwrap(store.add(name: "Home", urlString: "http://lan.invalid:3090", token: "test",
                                              secondaryEndpoint: .init(urlString: "https://relay.invalid:18443")))
        defer { store.delete(profile) }
        let client = try XCTUnwrap(store.client(for: profile))
        store.networkDidChange(old: nil, new: wifi)
        await store.prepareEndpoint(for: profile)
        await probes.setLANHealthy(false)
        let snapshot = client.transport.snapshot
        client.transport.report(snapshot, source: .webSocket, success: false)
        client.transport.report(snapshot, source: .http, success: true)
        await Task.yield()
        let before = await probes.calls
        XCTAssertEqual(before.count, 2)
        let reprobed = expectation(description: "Repeated failures re-probe")
        await probes.setNextProbeExpectation(reprobed)
        client.transport.report(snapshot, source: .webSocket, success: false)
        await fulfillment(of: [reprobed], timeout: 3)
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(client.baseURL.host, "relay.invalid")
        let count = await probes.calls.count
        XCTAssertEqual(count, 4)
        // Old HTTP completions / socket callbacks must not trigger another scan.
        client.transport.report(snapshot, source: .http, success: false)
        client.transport.report(snapshot, source: .http, success: false)
        await Task.yield()
        await store.prepareEndpoint(for: profile)
        let finalCount = await probes.calls.count
        XCTAssertEqual(finalCount, 4)
    }

    func testLateWiFiProbeCannotReplaceNewCellularChoice() async throws {
        let gate = ProbeGate()
        let suite = "I6-stale-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "First LAN probe suspended")
        let store = ServerStore(defaults: defaults) { endpoint, _, _, _ in
            await gate.check(endpoint, started: started)
        }
        let profile = try XCTUnwrap(store.add(name: "Home", urlString: "http://lan.invalid:3090", token: "test",
                                              secondaryEndpoint: .init(urlString: "https://relay.invalid:18443")))
        defer { store.delete(profile) }
        store.networkDidChange(old: nil, new: wifi)
        let old = Task { await store.prepareEndpoint(for: profile) }
        await fulfillment(of: [started], timeout: 3)
        store.networkDidChange(old: wifi, new: cellular)
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(store.endpointLabel(for: profile), "Relay")
        await gate.release()
        await old.value
        XCTAssertEqual(store.endpointLabel(for: profile), "Relay")
    }

    func testProbeTimeoutsDoNotWaitForConnectivity() {
        for timeout in [1.5, 5.0] {
            let config = EndpointProbe.configuration(timeout: timeout)
            XCTAssertFalse(config.waitsForConnectivity)
            XCTAssertEqual(config.timeoutIntervalForRequest, timeout)
            XCTAssertEqual(config.timeoutIntervalForResource, timeout)
        }
    }

    func testConfiguredRelayPrimaryUsesRelayTimeout() async throws {
        let probes = ProbeRecorder()
        let suite = "I6-primary-relay-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults) { endpoint, token, headers, timeout in
            await probes.check(endpoint, token: token, headers: headers, timeout: timeout)
        }
        let profile = try XCTUnwrap(store.add(name: "Relay", urlString: "https://relay.invalid:18443", token: "test", pairingMode: "relay",
                                              secondaryEndpoint: .init(urlString: "https://backup.invalid:18444")))
        defer { store.delete(profile) }
        await store.prepareEndpoint(for: profile)
        let calls = await probes.calls
        XCTAssertEqual(calls.map(\.timeout), [5, 5])
    }
}

private actor ProbeRecorder {
    struct Call { let endpoint: ServerEndpoint; let headers: [HeaderPair]; let timeout: TimeInterval }
    private(set) var calls: [Call] = []
    private var lanHealthy = true
    private var nextProbe: XCTestExpectation?
    func setLANHealthy(_ value: Bool) { lanHealthy = value }
    func setNextProbeExpectation(_ value: XCTestExpectation) { nextProbe = value }
    func check(_ endpoint: ServerEndpoint, token: String, headers: [HeaderPair], timeout: TimeInterval) -> Bool {
        calls.append(Call(endpoint: endpoint, headers: headers, timeout: timeout))
        nextProbe?.fulfill()
        nextProbe = nil
        return endpoint.urlString.contains("relay.invalid") || lanHealthy
    }
}

private actor ProbeGate {
    private var held = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func check(_ endpoint: ServerEndpoint, started: XCTestExpectation) async -> Bool {
        guard endpoint.urlString.contains("lan.invalid"), !held else { return true }
        held = true
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() { continuation?.resume(returning: true); continuation = nil }
}
