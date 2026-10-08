import XCTest
@testable import Codeg

final class EndpointTransportTests: XCTestCase {
    func testInvalidatedFacadeCannotStartHTTPOrNewSockets() async throws {
        let url = URL(string: "http://removed.invalid:18400")!
        let client = CodegClient(baseURL: url, token: "test")
        let snapshot = client.transport.snapshot
        client.transport.invalidate()
        XCTAssertFalse(client.transport.isCurrent(snapshot.generation))
        do {
            _ = try await client.health()
            XCTFail("Removed server client remained usable")
        } catch APIError.connectionLost(let reason) {
            XCTAssertEqual(reason, "endpoint changed")
        }
        let event = client.makeEventStream()
        let terminal = client.makeTerminalSocket()
        event.start()
        terminal.start()
        var events = event.frames.makeAsyncIterator()
        var terminals = terminal.frames.makeAsyncIterator()
        guard case .closed = await events.next(), case .closed = await terminals.next() else {
            return XCTFail("Late sockets must close before creating an invalid session task")
        }
    }

    func testRetiredSessionRejectsLateHTTPTaskCreationWithoutException() async throws {
        let url = URL(string: "http://retired.invalid:18400")!
        let sessions = SessionFactory.Sessions(baseURL: url, pin: nil)
        let client = CodegClient(baseURL: url, token: "test", sessions: sessions)
        sessions.invalidate(cancelOutstanding: true)
        do {
            _ = try await client.health()
            XCTFail("Retired sessions accepted a late request")
        } catch {
            XCTAssertTrue(APIError.isCancellation(error))
        }
    }
    func testInflightOldHTTPResultCannotSucceedOrPolluteNewGeneration() async throws {
        let started = expectation(description: "Old request started")
        SwitchingHTTPFixture.started = started
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SwitchingHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); SwitchingHTTPFixture.reset() }
        let lan = URL(string: "http://switch-lan.invalid:3090")!
        let relay = URL(string: "https://switch-relay.invalid:18443")!
        let outcomes = OutcomeRecorder()
        let transport = ConnectionTransport(baseURL: lan, token: "test", customHeaders: [],
                                            sessions: .init(baseURL: lan, pin: nil), sessionOverride: session,
                                            onOutcome: { _, _, success in outcomes.append(success) })
        let client = CodegClient(transport: transport)
        let oldRequest = Task { try await client.health() }
        await fulfillment(of: [started], timeout: 3)
        transport.replace(baseURL: relay, token: "test", customHeaders: [],
                          sessions: .init(baseURL: relay, pin: nil), sessionOverride: session)
        SwitchingHTTPFixture.releaseOld()
        do {
            _ = try await oldRequest.value
            XCTFail("A stale endpoint response must not be adopted")
        } catch APIError.connectionLost(let reason) {
            XCTAssertEqual(reason, "endpoint changed")
        }
        let health = try await client.health()
        XCTAssertEqual(health.version, "relay")
        XCTAssertEqual(outcomes.values, [true], "The obsolete request cannot affect failure accounting")
    }
    func testSwitchUpdatesCapturedClientAndNotifiesBothSocketsOnce() async throws {
        let lan = URL(string: "http://lan.invalid:3090")!
        let relay = URL(string: "https://relay.invalid:18443")!
        let transport = ConnectionTransport(baseURL: lan, token: "test", customHeaders: [],
                                            sessions: .init(baseURL: lan, pin: nil))
        let capturedClient = CodegClient(transport: transport)
        let event = capturedClient.makeEventStream()
        let terminal = capturedClient.makeTerminalSocket()
        // Suspended sockets exercise lifecycle without any network request.
        let originalSession = capturedClient.streamSession
        transport.replace(baseURL: relay, token: "test", customHeaders: [.init(name: "X-Test", value: "secret")],
                          sessions: .init(baseURL: relay, pin: String(repeating: "ab", count: 32)))
        XCTAssertEqual(capturedClient.baseURL, relay)
        XCTAssertEqual(capturedClient.customHeaders.first?.value, "secret")
        XCTAssertFalse(capturedClient.streamSession === originalSession)
        var events = event.frames.makeAsyncIterator()
        var terminals = terminal.frames.makeAsyncIterator()
        guard case .closed(let eventReason) = await events.next(),
              case .closed(let terminalReason) = await terminals.next() else {
            return XCTFail("Switch must notify both consumers")
        }
        XCTAssertEqual(eventReason, "endpoint changed")
        XCTAssertEqual(terminalReason, "endpoint changed")
        let eventEnd = await events.next()
        let terminalEnd = await terminals.next()
        XCTAssertNil(eventEnd)
        XCTAssertNil(terminalEnd)
    }

    func testEndpointChangeSkipsRecoveryBackoff() {
        var schedule = ReconnectSchedule()
        for _ in 0..<8 { _ = schedule.next(unitRandom: 1) }
        XCTAssertEqual(schedule.next(closeReason: "endpoint changed", unitRandom: 1), 0)
    }

    func testHeaderSecretsCannotFollowCrossOriginRedirects() {
        let trust = TrustEvaluator(baseURL: URL(string: "http://lan.invalid:3090")!, pin: nil)
        XCTAssertTrue(trust.allowsRedirect(to: URL(string: "http://lan.invalid:3090/new")!))
        XCTAssertFalse(trust.allowsRedirect(to: URL(string: "http://other.invalid:3090/new")!))
        XCTAssertFalse(trust.allowsRedirect(to: URL(string: "https://lan.invalid:3090/new")!))
    }
}

private final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.withLock { stored } }
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
}

private final class SwitchingHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var old: SwitchingHTTPFixture?
    static var started: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool {
        ["switch-lan.invalid", "switch-relay.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "switch-lan.invalid" {
            Self.lock.withLock { Self.old = self }
            Self.started?.fulfill()
        } else { respond(version: "relay") }
    }
    override func stopLoading() {}
    private func respond(version: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"ok\",\"version\":\"\(version)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    static func releaseOld() {
        let value = lock.withLock { let value = old; old = nil; return value }
        value?.respond(version: "old")
    }
    static func reset() { lock.withLock { old = nil }; started = nil }
}
