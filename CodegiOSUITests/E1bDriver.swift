import XCTest
import UIKit

/// Test-only command runner. It drives the unmodified fork through accessibility.
/// Its loopback controller and disposable credential never enter XCTest activities.
final class E1bDriver: XCTestCase {
    @MainActor
    func testDriveSimulator() async throws {
        continueAfterFailure = false
        guard let file = Bundle(for: Self.self).url(forResource: "E1bController", withExtension: "json") else {
            throw XCTSkip("E1b loopback UI controller is not configured")
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: String]
        let base = try XCTUnwrap(config["url"])
        let bundleID = config["bundleID"] ?? "app.codeg.ios.fork.yourname"
        XCTAssertTrue(bundleID == "app.codeg.ios.fork" || bundleID.hasPrefix("app.codeg.ios.fork."))
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        defer { UIPasteboard.general.string = nil }
        while true {
            let (data, _) = try await session.data(from: URL(string: base + "/next")!)
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let action = command["action"] as? String ?? "noop"
            if action == "noop" { continue }
            if action == "finish" { break }
            var result: [String: Any] = ["id": command["id"]!, "action": action]
            let label = command["label"] as? String ?? ""
            let type = command["type"] as? String ?? "any"
            let query: XCUIElementQuery
            switch type {
            case "button": query = app.buttons
            case "textField": query = app.textFields
            case "secureTextField": query = app.secureTextFields
            case "textView": query = app.textViews
            case "staticText": query = app.staticTexts
            default: query = app.descendants(matching: .any)
            }
            let matches = label.isEmpty ? query : query.matching(NSPredicate(
                format: command["contains"] as? Bool == true ? "label CONTAINS %@" : "label == %@", label))
            let element = matches.element(boundBy: command["index"] as? Int ?? 0)
            switch action {
            case "tap":
                if element.exists { element.tap() } else { result["error"] = "element missing" }
            case "longPress":
                if element.exists { element.press(forDuration: 1.1) } else { result["error"] = "element missing" }
            case "type":
                if element.exists {
                    element.tap()
                    if command["clear"] as? Bool == true, let value = element.value as? String {
                        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
                    }
                    element.typeText(command["text"] as? String ?? "")
                } else { result["error"] = "element missing" }
            case "typeFocused":
                app.typeText(command["text"] as? String ?? "")
            case "pasteSecret":
                let (secret, _) = try await session.data(from: URL(string: base + "/secret")!)
                UIPasteboard.general.string = String(data: secret, encoding: .utf8)
                element.tap()
                element.press(forDuration: 1.1)
                let paste = app.menuItems["Paste"]
                if paste.waitForExistence(timeout: 3) { paste.tap() }
                else if app.buttons["Paste"].exists { app.buttons["Paste"].tap() }
                else { result["error"] = "paste menu missing" }
            case "coordinate":
                let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                origin.withOffset(CGVector(dx: command["x"] as! Double, dy: command["y"] as! Double)).tap()
            case "drag":
                let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                let start = origin.withOffset(CGVector(dx: command["x"] as! Double, dy: command["y"] as! Double))
                let end = origin.withOffset(CGVector(dx: command["toX"] as! Double, dy: command["toY"] as! Double))
                start.press(forDuration: 0.05, thenDragTo: end)
            case "swipeUp": app.swipeUp()
            case "swipeDown": app.swipeDown()
            case "home": XCUIDevice.shared.press(.home)
            case "activate": app.activate()
            case "launch": app.launch()
            case "state": break
            case "frames":
                result["frames"] = matches.allElementsBoundByIndex.map {
                    ["label": $0.label, "x": $0.frame.minX, "y": $0.frame.minY,
                     "width": $0.frame.width, "height": $0.frame.height] as [String: Any]
                }
            default: result["error"] = "unsupported action"
            }
            result["tree"] = app.debugDescription
            result["textViews"] = app.textViews.allElementsBoundByIndex.map { $0.value as? String ?? "" }
            if command["screenshot"] as? Bool == true {
                result["png"] = app.screenshot().pngRepresentation.base64EncodedString()
            }
            var request = URLRequest(url: URL(string: base + "/result")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: result)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try await session.data(for: request)
        }
    }
}
