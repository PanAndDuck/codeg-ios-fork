import XCTest
@testable import Codeg

/// Opt-in real TLS/WSS coverage. scripts/test-pinning.sh generates a short-lived
/// loopback certificate + this fixture resource, then removes both after XCTest.
final class PinningIntegrationTests: XCTestCase {
    private enum StreamFailure: Error { case ended, timedOut }

    private func firstFrame<T: Sendable>(from frames: AsyncStream<T>) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var iterator = frames.makeAsyncIterator()
                guard let frame = await iterator.next() else { throw StreamFailure.ended }
                return frame
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw StreamFailure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct Fixture: Decodable {
        let url: URL
        let fingerprint: String
    }

    private func fixture() throws -> Fixture {
        guard let url = Bundle(for: Self.self).url(forResource: "LocalTLSFixture", withExtension: "json") else {
            throw XCTSkip("Run scripts/test-pinning.sh to enable the local TLS fixture.")
        }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        guard value.url.host == "127.0.0.1", let port = value.url.port, (18400...18499).contains(port) else {
            throw XCTSkip("TLS fixture must use the assigned loopback port range.")
        }
        return value
    }

    func testUnpinnedSelfSignedHealthReturnsPresentedFingerprint() async throws {
        let fixture = try fixture()
        let client = CodegClient(baseURL: fixture.url, token: "test-only")
        do {
            _ = try await client.health()
            XCTFail("Self-signed certificate was accepted without a pin")
        } catch APIError.untrustedCertificate(let fingerprint) {
            XCTAssertEqual(fingerprint, fixture.fingerprint)
        }
    }

    func testPinnedHealthAndEverySessionKindAcceptMatchingCertificate() async throws {
        let fixture = try fixture()
        let factory = SessionFactory()
        let profile = ServerProfile(name: "Test", urlString: fixture.url.absoluteString, pinnedCertSHA256: fixture.fingerprint)
        let sessions = factory.sessions(for: profile)
        let client = CodegClient(baseURL: fixture.url, token: "test-only", sessions: sessions)
        let health = try await client.health()
        XCTAssertEqual(health.version, "test")
        for kind in [SessionFactory.Kind.standard, .probe, .install] {
            let response: HealthResponse = try await client.postJSON("health", EmptyBody(), session: sessions[kind])
            XCTAssertEqual(response.status, "ok")
        }
    }

    func testMismatchedPinRejectsHTTPAndWebSocket() async throws {
        let fixture = try fixture()
        let sessions = SessionFactory.Sessions(baseURL: fixture.url, pin: String(repeating: "00", count: 32))
        let client = CodegClient(baseURL: fixture.url, token: "test-only", sessions: sessions)
        do {
            _ = try await client.health()
            XCTFail("Mismatched pin accepted")
        } catch APIError.untrustedCertificate(let fingerprint) {
            XCTAssertEqual(fingerprint, fixture.fingerprint)
        }
        let stream = EventStream(baseURL: client.baseURL, token: client.token, session: client.streamSession)
        defer { stream.close() }
        stream.start()
        let frame = try await firstFrame(from: stream.frames)
        guard case .closed = frame else { return XCTFail("Mismatched WSS certificate accepted") }
    }

    func testConnectionBudgetDoesNotCancelAnAlreadySentSlowOperation() async throws {
        let fixture = try fixture()
        let url = fixture.url.appendingPathComponent("slow")
        let sessions = SessionFactory.Sessions(baseURL: url, pin: fixture.fingerprint, connectionTimeout: 0.3)
        let client = CodegClient(baseURL: url, token: "test-only", sessions: sessions)
        let start = ProcessInfo.processInfo.systemUptime
        let response: HealthResponse = try await client.postJSON("health", EmptyBody(), kind: .probe)
        XCTAssertEqual(response.status, "ok")
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    @MainActor
    func testFirstFailedWebSocketUpgradeSelectsRelayBeforeClosing() async throws {
        let fixture = try fixture()
        let suite = "F3-ws-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        let profile = try XCTUnwrap(store.add(name: "F3", urlString: fixture.url.appendingPathComponent("stall").absoluteString,
            token: "test-only", pinnedCertSHA256: fixture.fingerprint,
            secondaryEndpoint: .init(urlString: fixture.url.absoluteString, pinnedCertSHA256: fixture.fingerprint)))
        defer { store.delete(profile) }
        let client = try XCTUnwrap(store.client(for: profile))
        store.networkDidChange(old: nil, new: .init(status: .satisfied, primaryInterface: .wifi))
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(store.endpointLabel(for: profile), "LAN")
        let start = ProcessInfo.processInfo.systemUptime
        let stream = client.makeEventStream()
        defer { stream.close() }
        stream.start()
        guard case .closed(let reason) = try await firstFrame(from: stream.frames) else { return XCTFail("Expected failover") }
        XCTAssertEqual(reason, EventStream.CloseReason.endpointChanged)
        XCTAssertEqual(store.endpointLabel(for: profile), "Relay")
        let replacement = client.makeEventStream()
        defer { replacement.close() }
        replacement.start()
        guard case .ready = try await firstFrame(from: replacement.frames) else { return XCTFail("Relay upgrade failed") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
    }

    func testPinnedEventAndTerminalWebSocketsReceiveReady() async throws {
        let fixture = try fixture()
        let sessions = SessionFactory.Sessions(baseURL: fixture.url, pin: fixture.fingerprint)
        let stream = EventStream(baseURL: fixture.url, token: "test-only", session: sessions[.stream])
        defer { stream.close() }
        stream.start()
        let eventFrame = try await firstFrame(from: stream.frames)
        guard case .ready = eventFrame else { return XCTFail("Pinned EventStream did not reach ready: \(eventFrame)") }
        let terminal = TerminalSocket(baseURL: fixture.url, token: "test-only", session: sessions[.stream])
        defer { terminal.close() }
        terminal.start()
        let terminalFrame = try await firstFrame(from: terminal.frames)
        guard case .ready = terminalFrame else { return XCTFail("Pinned TerminalSocket did not reach ready: \(terminalFrame)") }
    }

    func testCustomHeadersReachHTTPAndBothPinnedWebSockets() async throws {
        let fixture = try fixture()
        let url = fixture.url.appendingPathComponent("headers")
        let sessions = SessionFactory.Sessions(baseURL: url, pin: fixture.fingerprint)
        let client = CodegClient(baseURL: url, token: "test-only", sessions: sessions,
                                 customHeaders: [.init(name: "CF-Access-Client-Id", value: "fixture-id"),
                                                 .init(name: "CF-Access-Client-Secret", value: "fixture-secret")])
        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")
        let stream = client.makeEventStream()
        defer { stream.close() }
        stream.start()
        guard case .ready = try await firstFrame(from: stream.frames) else { return XCTFail("Event upgrade lost custom headers") }
        let terminal = client.makeTerminalSocket()
        defer { terminal.close() }
        terminal.start()
        guard case .ready = try await firstFrame(from: terminal.frames) else { return XCTFail("Terminal upgrade lost custom headers") }
    }

    func testEndpointProbeUsesHeadersAndRejectsWrongEndpointPin() async throws {
        let fixture = try fixture()
        let endpoint = ServerEndpoint(urlString: fixture.url.appendingPathComponent("headers").absoluteString,
                                      pinnedCertSHA256: fixture.fingerprint)
        let headers = [HeaderPair(name: "CF-Access-Client-Id", value: "fixture-id"),
                       HeaderPair(name: "CF-Access-Client-Secret", value: "fixture-secret")]
        let healthy = await EndpointProbe.check(endpoint, token: "test-only", headers: headers, timeout: 5)
        XCTAssertTrue(healthy)
        let missingHeaders = await EndpointProbe.check(endpoint, token: "test-only", headers: [], timeout: 5)
        XCTAssertFalse(missingHeaders)
        let wrongPin = ServerEndpoint(urlString: endpoint.urlString, pinnedCertSHA256: String(repeating: "00", count: 32))
        let trustedWrongly = await EndpointProbe.check(wrongPin, token: "test-only", headers: headers, timeout: 5)
        XCTAssertFalse(trustedWrongly)
    }

    func testAuthenticatedRedirectCannotChangeOriginOrScheme() async throws {
        let fixture = try fixture()
        for route in ["redirect-port", "redirect-scheme", "redirect-host"] {
            let url = fixture.url.appendingPathComponent(route)
            let client = CodegClient(baseURL: url, token: "test-only",
                                     sessions: .init(baseURL: url, pin: fixture.fingerprint),
                                     customHeaders: [.init(name: "X-Secret", value: "fixture-only")])
            do {
                _ = try await client.health()
                XCTFail("Cross-origin redirect was followed")
            } catch APIError.server(let status, _, _) {
                XCTAssertEqual(status, 307)
            }
        }
        let url = fixture.url.appendingPathComponent("redirect-same")
        let client = CodegClient(baseURL: url, token: "test-only", sessions: .init(baseURL: url, pin: fixture.fingerprint))
        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")
    }

    @MainActor
    func testRealDualEndpointFailoverRecreatesBothActiveSockets() async throws {
        let fixture = try fixture()
        let suite = "I6-live-failover-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        // Primary accepts WSS but its health endpoint is deliberately offline.
        let profile = try XCTUnwrap(store.add(name: "Fixture", urlString: fixture.url.appendingPathComponent("offline").absoluteString,
                                              token: "test-only", pinnedCertSHA256: fixture.fingerprint,
                                              secondaryEndpoint: .init(urlString: fixture.url.appendingPathComponent("headers").absoluteString,
                                                                       pinnedCertSHA256: fixture.fingerprint),
                                              customHeaders: [.init(name: "CF-Access-Client-Id", value: "fixture-id"),
                                                              .init(name: "CF-Access-Client-Secret", value: "fixture-secret")]))
        defer { store.delete(profile) }
        let client = try XCTUnwrap(store.client(for: profile))
        let event = client.makeEventStream()
        let terminal = client.makeTerminalSocket()
        defer { event.close(); terminal.close() }
        event.start()
        terminal.start()
        guard case .ready = try await firstFrame(from: event.frames),
              case .ready = try await firstFrame(from: terminal.frames) else { return XCTFail("Initial sockets did not open") }
        await store.prepareEndpoint(for: profile)
        XCTAssertEqual(store.endpointLabel(for: profile), "Relay")
        XCTAssertEqual(client.baseURL.path, "/headers")
        guard case .closed(let eventReason) = try await firstFrame(from: event.frames),
              case .closed(let terminalReason) = try await firstFrame(from: terminal.frames) else { return XCTFail("Old consumers were not notified") }
        XCTAssertEqual(eventReason, "endpoint changed")
        XCTAssertEqual(terminalReason, "endpoint changed")
        let newEvent = client.makeEventStream()
        let newTerminal = client.makeTerminalSocket()
        defer { newEvent.close(); newTerminal.close() }
        newEvent.start()
        newTerminal.start()
        guard case .ready = try await firstFrame(from: newEvent.frames),
              case .ready = try await firstFrame(from: newTerminal.frames) else { return XCTFail("Replacement sockets did not open") }
        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")
    }

    @MainActor
    func testEditorTOFUAndReplacementRequireExplicitAction() async throws {
        let fixture = try fixture()
        let model = ServerEditorModel()
        model.name = "Local TLS"
        model.urlString = fixture.url.absoluteString
        model.token = "test-only"
        await model.testConnection()
        XCTAssertEqual(model.testResult, .certificate(fingerprint: fixture.fingerprint, isMismatch: false))
        XCTAssertNil(model.pinnedCertSHA256)
        XCTAssertTrue(model.trustPresentedCertificate())
        await model.testConnection()
        XCTAssertEqual(model.testResult, .success(version: "test"))

        let changed = ServerEditorModel(editing: ServerProfile(name: "Old pin", urlString: fixture.url.absoluteString, pinnedCertSHA256: String(repeating: "00", count: 32)))
        changed.token = "test-only"
        await changed.testConnection()
        XCTAssertEqual(changed.testResult, .certificate(fingerprint: fixture.fingerprint, isMismatch: true))
        XCTAssertFalse(changed.trustPresentedCertificate())
        XCTAssertTrue(changed.trustPresentedCertificate(replacingPin: true))
        await changed.testConnection()
        XCTAssertEqual(changed.testResult, .success(version: "test"))
    }

    @MainActor
    func testSavedProfileStatusUsesPinnedHealthSession() async throws {
        let fixture = try fixture()
        let suite = "I5-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        let profile = try XCTUnwrap(store.add(name: "Fixture", urlString: fixture.url.absoluteString,
                                              token: "test-only", pinnedCertSHA256: fixture.fingerprint))
        defer { store.delete(profile) }
        let statuses = ServerStatusModel(store: store)
        await statuses.refresh(profile)
        XCTAssertEqual(statuses.status(for: profile.id), .online(version: "test"))
    }

    @MainActor
    func testEditedEndpointCannotTrustStaleCertificateResult() async throws {
        let fixture = try fixture()
        let model = ServerEditorModel()
        model.urlString = fixture.url.absoluteString
        model.token = "test-only"
        await model.testConnection()
        model.urlString = "https://different.invalid:18443"
        XCTAssertNil(model.testResult)
        XCTAssertFalse(model.trustPresentedCertificate())
        XCTAssertNil(model.pinnedCertSHA256)
    }

    @MainActor
    func testSecondaryTOFUOnlyChangesSecondaryPinAndTargetChangeClearsResult() async throws {
        let fixture = try fixture()
        let primaryPin = String(repeating: "ab", count: 32)
        let profile = ServerProfile(name: "Home", urlString: "https://lan.invalid:18400", pinnedCertSHA256: primaryPin,
                                    secondaryEndpoint: .init(urlString: fixture.url.absoluteString))
        let model = ServerEditorModel(editing: profile)
        model.token = "test-only"
        model.testEndpoint = .secondary
        await model.testConnection()
        XCTAssertEqual(model.testResult, .certificate(fingerprint: fixture.fingerprint, isMismatch: false))
        model.testEndpoint = .primary
        XCTAssertNil(model.testResult)
        XCTAssertFalse(model.trustPresentedCertificate())
        model.testEndpoint = .secondary
        await model.testConnection()
        XCTAssertTrue(model.trustPresentedCertificate())
        XCTAssertEqual(model.pinnedCertSHA256, primaryPin)
        XCTAssertEqual(model.secondaryPinnedCertSHA256, fixture.fingerprint)
        await model.testConnection()
        XCTAssertEqual(model.testResult, .success(version: "test"))
    }
}
