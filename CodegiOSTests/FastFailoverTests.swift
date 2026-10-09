import XCTest
@testable import Codeg

@MainActor
final class FastFailoverTests: XCTestCase {
    func testConnectionDeadlineAndFirstFailureUseFakeClock() {
        var now: TimeInterval = 100
        var deadline = ConnectionDeadline(timeout: 1.5, clock: { now })
        var selector = EndpointSelector()
        selector.accept(onWiFi: true, primaryHealthy: true, secondaryHealthy: true)
        now = 101.499
        XCTAssertFalse(deadline.expired(bytesSent: 0))
        XCTAssertFalse(selector.needsProbe)
        now = 101.5
        XCTAssertTrue(deadline.expired(bytesSent: 0))
        selector.recordConnectivityFailure()
        XCTAssertTrue(selector.needsProbe, "The first failure has no backoff or second-failure threshold")
        selector.accept(onWiFi: true, primaryHealthy: true, secondaryHealthy: true)
        XCTAssertEqual(selector.choice, .secondary, "A fresh primary health response cannot hide the failed operation")
        now += 60
        XCTAssertFalse(selector.needsProbe)
        var connected = ConnectionDeadline(timeout: 1.5, clock: { now })
        XCTAssertFalse(connected.expired(bytesSent: 1))
        now += 900
        XCTAssertFalse(connected.expired(bytesSent: 0), "An established long operation keeps its original budget")
    }

    func testConnectivityClassificationExcludesCancellationTLSAndHTTP() {
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed] {
            XCTAssertTrue(EndpointFailover.isConnectivityFailure(URLError(code)), "\(code)")
        }
        for error: Error in [URLError(.cancelled), CancellationError(), URLError(.serverCertificateUntrusted),
                             URLError(.secureConnectionFailed), APIError.unauthorized, APIError.relayAgentOffline("fixture")] {
            XCTAssertFalse(EndpointFailover.isConnectivityFailure(error))
        }
    }

    func testSentMutationsAreNotReplayedButSessionReadsAndUnsentConnectAre() {
        for path in ["acp_prompt", "acp_connect", "terminal_spawn", "acp_respond_permission", "create_chat_conversation"] {
            XCTAssertFalse(EndpointFailover.mayReplay(path: path, kind: .standard, sentBodyBytes: 1), path)
            XCTAssertTrue(EndpointFailover.mayReplay(path: path, kind: .standard, sentBodyBytes: 0), path)
        }
        for path in ["get_folder_conversation", "list_all_folder_details", "acp_get_session_snapshot", "acp_find_connection_for_conversation"] {
            XCTAssertTrue(EndpointFailover.mayReplay(path: path, kind: .standard, sentBodyBytes: 100), path)
        }
    }

    func testSingleEndpointHealthIsBoundedButLongOperationsKeepTheirBudgets() {
        let sessions = SessionFactory.Sessions(baseURL: URL(string: "http://single.invalid:3097")!, pin: nil)
        XCTAssertFalse(sessions[.health].configuration.waitsForConnectivity)
        XCTAssertEqual(sessions[.health].configuration.timeoutIntervalForResource, 5)
        XCTAssertTrue(sessions[.read].configuration.waitsForConnectivity)
        XCTAssertEqual(sessions[.read].configuration.timeoutIntervalForResource, 60)
        XCTAssertEqual(sessions[.probe].configuration.timeoutIntervalForResource, 150)
        XCTAssertNil(sessions.connectionTimeout)
    }

    func testFirstFailureCoalescesParallelHTTPAndSocketSelection() async throws {
        let probes = FastProbeRecorder()
        let suite = "F3-select-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults) { endpoint, _, _, _ in await probes.check(endpoint) }
        let pin = String(repeating: "ab", count: 32)
        let profile = try XCTUnwrap(store.add(name: "F3", urlString: "http://lan.invalid:3097", token: "fixture",
             secondaryEndpoint: .init(urlString: "https://relay.invalid:18488", pinnedCertSHA256: pin)))
        defer { store.delete(profile) }
        let client = try XCTUnwrap(store.client(for: profile))
        store.networkDidChange(old: nil, new: .init(status: .satisfied, primaryInterface: .wifi))
        await store.prepareEndpoint(for: profile)
        let snapshot = client.transport.snapshot
        await probes.loseLAN()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for i in 0..<20 {
                group.addTask { await client.transport.recover(snapshot, source: i.isMultiple(of: 2) ? .http : .webSocket) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(client.baseURL.host, "relay.invalid")
        XCTAssertEqual(client.transport.snapshot.sessions.pin, pin)
        XCTAssertEqual(client.transport.snapshot.sessions.connectionTimeout, 5)
        let count = await probes.count
        XCTAssertEqual(count, 4, "Only one pair of probes after the cached startup pair")
        store.delete(profile)
        XCTAssertFalse(client.transport.canRetry(snapshot), "Deletion revokes retry permission")
    }

    func testEveryConnectivityErrorRetriesExactlyOnceOnSecondary() async throws {
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet] {
            let fixture = FailoverHTTPHarness(error: code)
            let result = try await fixture.client.health()
            XCTAssertEqual(result.version, "relay")
            XCTAssertEqual(FastHTTPProtocol.hosts, ["lan.invalid", "relay.invalid"])
            XCTAssertEqual(fixture.selections, 1)
            fixture.close()
        }
    }

    func testFailedSecondaryIsNotRetriedAgain() async throws {
        let fixture = FailoverHTTPHarness(error: .cannotConnectToHost, secondaryFails: true)
        defer { fixture.close() }
        do { _ = try await fixture.client.health(); XCTFail("Both endpoints fail") }
        catch { XCTAssertTrue(error is APIError) }
        XCTAssertEqual(FastHTTPProtocol.hosts, ["lan.invalid", "relay.invalid"])
    }

    func testCancellationAndTLSDoNotSelectOrRetry() async throws {
        for code: URLError.Code in [.cancelled, .serverCertificateUntrusted, .secureConnectionFailed] {
            let fixture = FailoverHTTPHarness(error: code)
            do { _ = try await fixture.client.health(); XCTFail("Expected transport rejection") } catch {}
            XCTAssertEqual(FastHTTPProtocol.hosts, ["lan.invalid"])
            XCTAssertEqual(fixture.selections, 0)
            fixture.close()
        }
    }

    func testConnectionDeadlineCancelsHungLANAndRetriesUnsentSessionConnect() async throws {
        let fixture = FailoverHTTPHarness(error: .timedOut, hangs: true)
        defer { fixture.close() }
        let start = ProcessInfo.processInfo.systemUptime
        _ = try await fixture.client.send("acp_connect", body: EmptyBody(), kind: .probe)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(FastHTTPProtocol.hosts, ["lan.invalid", "relay.invalid"])
    }

    func testLateTLSFailureCannotReplayAfterConcurrentEndpointSwitch() async throws {
        let fixture = FailoverHTTPHarness(error: .secureConnectionFailed, hangs: true)
        defer { fixture.close() }
        let started = expectation(description: "Old TLS request in flight")
        FastHTTPProtocol.started = started
        let operation = Task { try await fixture.client.health() }
        await fulfillment(of: [started], timeout: 2)
        fixture.select(fixture.client.transport.snapshot.generation)
        FastHTTPProtocol.failHeld(.secureConnectionFailed)
        do { _ = try await operation.value; XCTFail("TLS failure was replayed") }
        catch APIError.tls {}
        XCTAssertEqual(FastHTTPProtocol.hosts, ["lan.invalid"])
    }

    func testDualEndpointSessionsFailFastWithoutShorteningLongOperations() throws {
        let suite = "F3-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        let profile = try XCTUnwrap(store.add(name: "F3", urlString: "http://lan.invalid:3097", token: "fixture",
                                              secondaryEndpoint: .init(urlString: "https://relay.invalid:18488")))
        defer { store.delete(profile) }
        let client = try XCTUnwrap(store.client(for: profile))
        for kind in SessionFactory.Kind.allCases {
            XCTAssertFalse(client.transport.snapshot.session(kind).configuration.waitsForConnectivity, "\(kind)")
        }
        XCTAssertEqual(client.probeSession.configuration.timeoutIntervalForRequest, 90)
        XCTAssertEqual(client.installSession.configuration.timeoutIntervalForResource, 900)
        XCTAssertEqual(client.streamSession.configuration.timeoutIntervalForResource, 604_800)
    }
}

private actor FastProbeRecorder {
    private(set) var count = 0
    private var lanHealthy = true
    func loseLAN() { lanHealthy = false }
    func check(_ endpoint: ServerEndpoint) -> Bool {
        count += 1
        return endpoint.urlString.contains("relay") || lanHealthy
    }
}

@MainActor
private final class FailoverHTTPHarness {
    let lan = URL(string: "http://lan.invalid:3097")!
    let relay = URL(string: "http://relay.invalid:18488")!
    let session: URLSession
    private(set) var selections = 0
    private var transport: ConnectionTransport!
    var client: CodegClient { CodegClient(transport: transport) }

    init(error: URLError.Code, secondaryFails: Bool = false, hangs: Bool = false) {
        FastHTTPProtocol.configure(error: error, secondaryFails: secondaryFails, hangs: hangs)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FastHTTPProtocol.self]
        session = URLSession(configuration: config)
        transport = ConnectionTransport(baseURL: lan, token: "fixture", customHeaders: [],
            sessions: .init(baseURL: lan, pin: nil, connectionTimeout: 0.05), sessionOverride: session,
            onConnectivityFailure: { [weak self] generation, _ in await self?.select(generation) })
    }

    func select(_ generation: UUID) {
        selections += 1
        guard transport.snapshot.baseURL == lan else { return }
        transport.replace(baseURL: relay, token: "fixture", customHeaders: [],
            sessions: .init(baseURL: relay, pin: nil, connectionTimeout: 0.05), sessionOverride: session,
            retryFromGeneration: generation)
    }

    func close() { transport.invalidate(); session.invalidateAndCancel() }
}

private final class FastHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var error = URLError.Code.cannotConnectToHost
    private static var secondaryFails = false
    private static var hangs = false
    private static var requests: [String] = []
    private static var held: FastHTTPProtocol?
    static var started: XCTestExpectation?
    static var hosts: [String] { lock.withLock { requests } }

    static func configure(error: URLError.Code, secondaryFails: Bool, hangs: Bool) {
        lock.withLock { self.error = error; self.secondaryFails = secondaryFails; self.hangs = hangs; requests = []; held = nil; started = nil }
    }
    static func failHeld(_ code: URLError.Code) {
        let held = lock.withLock { let value = self.held; self.held = nil; return value }
        held?.client?.urlProtocol(held!, didFailWithError: URLError(code))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let (error, fails, hangs) = Self.lock.withLock {
            Self.requests.append(host)
            return (Self.error, host == "lan.invalid" || Self.secondaryFails, Self.hangs && host == "lan.invalid")
        }
        if hangs {
            Self.lock.withLock { Self.held = self }
            Self.started?.fulfill()
            return
        }
        if fails { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"ok\",\"version\":\"relay\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
