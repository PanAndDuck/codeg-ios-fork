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
}
