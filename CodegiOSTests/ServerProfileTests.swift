import XCTest
@testable import Codeg

final class ServerProfileTests: XCTestCase {
    func testUppercaseHTTPSStillProducesSecureWebSocketURL() throws {
        let profile = ServerProfile(name: "Relay", urlString: "HTTPS://example.test:18443",
                                    pinnedCertSHA256: String(repeating: "ab", count: 32))
        let url = try XCTUnwrap(profile.baseURL)
        XCTAssertEqual(EventStream.websocketURL(from: url).scheme, "wss")
    }

    func testOldProfileWithoutPairingFieldsDecodes() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"Old","urlString":"https://example.test","createdAt":0}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.pinnedCertSHA256)
        XCTAssertNil(profile.pairingMode)
        XCTAssertEqual(profile.name, "Old")
    }

    func testDecodedPinIsCanonicalAndMalformedPinFailsClosed() throws {
        let human = Array(repeating: "AB", count: 32).joined(separator: ":")
        func data(_ value: String) -> Data {
            Data("""
            {"id":"11111111-2222-3333-4444-555555555555","name":"Relay","urlString":"https://example.test","createdAt":0,"pinnedCertSHA256":"\(value)"}
            """.utf8)
        }
        let profile = try JSONDecoder().decode(ServerProfile.self, from: data("SHA256: \(human)"))
        XCTAssertEqual(profile.pinnedCertSHA256, String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try JSONDecoder().decode(ServerProfile.self, from: data("bad")))
    }

    func testCodableRoundTripPreservesProfile() throws {
        let profile = ServerProfile(
            id: try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            name: "测试 server",
            urlString: "https://example.test:18443/codeg",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: data), profile)
    }
}
