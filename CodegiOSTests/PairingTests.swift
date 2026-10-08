import XCTest
@testable import Codeg

@MainActor
final class PairingTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)

    func testUppercasePairingSchemeProducesWSS() throws {
        let pairing = try PairingPayload.parse("{\"url\":\"HTTPS://relay.test:18443\",\"fp\":\"\(pin)\"}")
        XCTAssertEqual(EventStream.websocketURL(from: pairing.url).scheme, "wss")
    }

    func testRelayQRImportsNormalizedPinAndAllFields() throws {
        let human = Array(repeating: "AB", count: 32).joined(separator: ":")
        let model = ServerEditorModel()
        model.name = "Old name"
        XCTAssertTrue(model.applyScanned("""
        {"v":1,"mode":"relay","url":"https://relay.test:18443","token":" token ","fp":"SHA256: \(human)","name":"Relay"}
        """))
        XCTAssertEqual(model.urlString, "https://relay.test:18443")
        XCTAssertEqual(model.token, "token")
        XCTAssertEqual(model.name, "Relay")
        XCTAssertEqual(model.pinnedCertSHA256, pin)
        XCTAssertEqual(model.pairingMode, "relay")
        XCTAssertTrue(model.canSave)
    }

    func testDirectAndPlainURLClearOldPin() {
        let model = ServerEditorModel(editing: ServerProfile(name: "Relay", urlString: "https://relay.test", pinnedCertSHA256: pin))
        XCTAssertTrue(model.applyScanned(#"{"v":1,"mode":"direct","url":"http://127.0.0.1:18443","token":"direct"}"#))
        XCTAssertNil(model.pinnedCertSHA256)
        XCTAssertEqual(model.pairingMode, "direct")
        XCTAssertTrue(model.applyScanned("https://legacy.test"))
        XCTAssertNil(model.pairingMode)
    }

    func testInvalidPinsAndModesFailAtomicallyWithUsefulError() {
        for extra in [#""fp":"zz""#, #""fp":42"#, #""fp":null"#, #""mode":"unknown""#] {
            let model = ServerEditorModel(editing: ServerProfile(name: "Original", urlString: "https://original.test", pinnedCertSHA256: pin))
            XCTAssertFalse(model.applyScanned("{\"url\":\"https://new.test\",\(extra)}"))
            XCTAssertNotNil(model.scanError)
            XCTAssertEqual(model.urlString, "https://original.test")
            XCTAssertEqual(model.pinnedCertSHA256, pin)
        }
    }

    func testPinCannotBeUsedWithPlaintextURL() {
        let model = ServerEditorModel()
        XCTAssertFalse(model.applyScanned("{\"url\":\"http://127.0.0.1:18443\",\"fp\":\"\(pin)\"}"))
        let pinned = ServerEditorModel(editing: ServerProfile(name: "Relay", urlString: "https://relay.test", pinnedCertSHA256: pin), hasExistingToken: true)
        pinned.urlString = "http://127.0.0.1:18443"
        XCTAssertFalse(pinned.canTest)
        XCTAssertFalse(pinned.canSave)
    }

    func testMalformedFingerprintDoesNotMutateEditor() {
        let model = ServerEditorModel()
        model.urlString = "https://original.test"
        model.token = "original-token"
        XCTAssertFalse(model.applyScanned(#"{"v":1,"mode":"relay","url":"https://relay.test:18443","token":"new-token","fp":"bad"}"#))
        XCTAssertEqual(model.urlString, "https://original.test")
        XCTAssertEqual(model.token, "original-token")
    }

    func testUnsupportedPairingVersionIsRejected() {
        XCTAssertFalse(ServerEditorModel().applyScanned(#"{"v":2,"mode":"relay","url":"https://relay.test:18443"}"#))
    }

    func testLegacyURLAndJSONStillImport() {
        let model = ServerEditorModel()
        XCTAssertTrue(model.applyScanned("http://127.0.0.1:18443?token=example%20token"))
        XCTAssertEqual(model.urlString, "http://127.0.0.1:18443")
        XCTAssertEqual(model.token, "example token")
        XCTAssertTrue(model.applyScanned(#"{"address":"https://example.test","token":"legacy","name":"Legacy"}"#))
        XCTAssertEqual(model.name, "Legacy")
        XCTAssertEqual(model.token, "legacy")
    }

    func testProfilePreservesPairingMetadataFromJSON() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","name":"Relay","urlString":"https://relay.test:18443","createdAt":0,"pinnedCertSHA256":"\(pin)","pairingMode":"relay"}
        """
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["pinnedCertSHA256"] as? String, pin)
        XCTAssertEqual(object["pairingMode"] as? String, "relay")
    }
}
