import XCTest
@testable import Codeg

final class RouteTests: XCTestCase {
    func testRegisteredSchemeOpensConversationAndProject() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = try XCTUnwrap(types.first?["CFBundleURLSchemes"] as? [String])
        let scheme = try XCTUnwrap(schemes.first)
        XCTAssertEqual(Route.from(url: try XCTUnwrap(URL(string: "\(scheme)://conversation/42"))), .conversation(42))
        XCTAssertEqual(Route.from(url: try XCTUnwrap(URL(string: "\(scheme)://project/7"))), .project(7))
    }

    func testContentLinksKeepCodegScheme() throws {
        XCTAssertEqual(Route.from(url: try XCTUnwrap(URL(string: "codeg://conversation/42"))), .conversation(42))
        XCTAssertNil(Route.from(url: try XCTUnwrap(URL(string: "https://conversation/42"))))
    }

    @MainActor
    func testRegisteredSchemeSwitchesTabs() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = try XCTUnwrap(types.first?["CFBundleURLSchemes"] as? [String])
        let scheme = try XCTUnwrap(schemes.first)
        let model = AppModel()
        model.isCompact = true
        model.handle(url: try XCTUnwrap(URL(string: "\(scheme)://tab/settings")))
        XCTAssertEqual(model.selectedTab, .settings)
    }
}
