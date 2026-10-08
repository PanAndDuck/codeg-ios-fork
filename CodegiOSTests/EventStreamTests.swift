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

    func testWebsocketURLCurrentlyReplacesBasePathAndDropsQuery() throws {
        // Characterizes the existing behavior. I1 will preserve the base path.
        let baseURL = try XCTUnwrap(URL(string: "https://example.test:18443/codeg/api?token=test"))
        XCTAssertEqual(EventStream.websocketURL(from: baseURL).absoluteString,
                       "wss://example.test:18443/ws/events")
    }
}
