import XCTest
@testable import Codeg

final class EventStreamTests: XCTestCase {
    func testBase64URLNoPadRemovesPadding() {
        XCTAssertEqual(EventStream.base64URLNoPad(""), "")
        XCTAssertEqual(EventStream.base64URLNoPad("f"), "Zg")
        XCTAssertEqual(EventStream.base64URLNoPad("fo"), "Zm8")
        XCTAssertEqual(EventStream.base64URLNoPad("foo"), "Zm9v")
    }

    func testBase64URLNoPadUsesURLSafeAlphabetForUTF8() {
        XCTAssertEqual(EventStream.base64URLNoPad("\u{FFFF}"), "77-_")
    }

    func testWebsocketURLMapsHTTPToWS() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:3090/"))
        XCTAssertEqual(EventStream.websocketURL(from: baseURL).absoluteString,
                       "ws://127.0.0.1:3090/ws/events")
    }

    func testWebsocketURLPreservesBasePathAndDropsQueryAndFragment() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.test:18443/codeg/api?token=test#section"))
        XCTAssertEqual(EventStream.websocketURL(from: baseURL).absoluteString,
                       "wss://example.test:18443/codeg/api/ws/events")
    }

    func testWebsocketURLHandlesTrailingSlashesAndUppercaseHTTPS() throws {
        let cases = [
            ("https://example.test", "wss://example.test/ws/events"),
            ("HTTPS://example.test/", "wss://example.test/ws/events"),
            ("https://example.test/prefix/", "wss://example.test/prefix/ws/events"),
            ("HTTP://example.test/prefix", "ws://example.test/prefix/ws/events"),
            ("ftp://example.test/prefix", "ws://example.test/prefix/ws/events"),
            ("https://example.test/a%2Fb/", "wss://example.test/a%2Fb/ws/events"),
        ]
        for (base, expected) in cases {
            XCTAssertEqual(EventStream.websocketURL(from: try XCTUnwrap(URL(string: base))).absoluteString,
                           expected, base)
        }
    }

    func testStreamSessionFailsFastWithoutReducingIdleTimeouts() {
        let configuration = EventStream.streamSession.configuration
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 604_800)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 604_800)
    }

    func testWebSocketTaskAllowsLargeSnapshotsBeforeResume() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = EventStream.makeWebSocketTask(
            session: session,
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:18400/ws/events")),
            token: "test-token"
        )
        defer { task.cancel() }
        XCTAssertEqual(task.maximumMessageSize, 64 * 1024 * 1024)
        XCTAssertEqual(task.state, .suspended)
    }
}
