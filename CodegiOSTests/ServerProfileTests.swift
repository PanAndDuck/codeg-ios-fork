import XCTest
@testable import Codeg

final class ServerProfileTests: XCTestCase {
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
