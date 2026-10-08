import XCTest
@testable import Codeg

@MainActor
final class PairingInputTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)

    func testPastedRelayUsesQRImportAndNormalizesPin() {
        let input = """
        {"v":1,"mode":"relay","url":"HTTPS://relay.invalid:18443/","token":" fixture ","fp":"SHA256: \(pin.uppercased())","name":" Home "}
        """
        let pasted = ServerEditorModel()
        let scanned = ServerEditorModel()
        XCTAssertTrue(pasted.applyPairingCode(input))
        XCTAssertTrue(scanned.applyScanned(input))
        for model in [pasted, scanned] {
            XCTAssertEqual(model.urlString, "https://relay.invalid:18443")
            XCTAssertEqual(model.token, "fixture")
            XCTAssertEqual(model.name, "Home")
            XCTAssertEqual(model.pinnedCertSHA256, pin)
            XCTAssertEqual(model.pairingMode, "relay")
            XCTAssertNil(model.pendingRelayPairing)
            XCTAssertTrue(model.canSave)
        }
    }

    func testTypedDirectPairingReplacesTrustMetadata() {
        let model = ServerEditorModel(editing: ServerProfile(name: "Old", urlString: "https://old.invalid", pinnedCertSHA256: pin, pairingMode: "relay"))
        XCTAssertTrue(model.applyPairingCode(#"{"v":1,"mode":"direct","url":"http://lan.invalid:3090","token":" direct-fixture ","name":"LAN"}"#))
        XCTAssertEqual(model.urlString, "http://lan.invalid:3090")
        XCTAssertEqual(model.token, "direct-fixture")
        XCTAssertEqual(model.name, "LAN")
        XCTAssertEqual(model.pairingMode, "direct")
        XCTAssertNil(model.pinnedCertSHA256)
        XCTAssertTrue(model.canSave)
    }

    func testPastedLegacyFormatsUseSameNormalizationAndTokenExtraction() {
        let inputs: [(String, String, String)] = [
            (" https://legacy.invalid/\n", "https://legacy.invalid", "existing-fixture"),
            ("http://lan.invalid:3090?token=fake%20token&keep=1", "http://lan.invalid:3090?keep=1", "fake token"),
            (#"{"address":"legacy.invalid:3090","token":"legacy-fixture"}"#, "http://legacy.invalid:3090", "legacy-fixture"),
            (#"{"server":"https://legacy.invalid","token":"server-fixture"}"#, "https://legacy.invalid", "server-fixture")
        ]
        for (input, url, token) in inputs {
            let model = ServerEditorModel()
            model.token = "existing-fixture"
            XCTAssertTrue(model.applyPairingCode(input))
            XCTAssertEqual(model.urlString, url)
            XCTAssertEqual(model.token, token)
            XCTAssertNil(model.pinnedCertSHA256)
            XCTAssertNil(model.pairingMode)
        }
    }

    func testMalformedPasteIsAtomicAndClearsPendingRelayOffer() {
        let profile = ServerProfile(name: "Original", urlString: "https://lan.invalid:3090", pinnedCertSHA256: pin, pairingMode: "direct",
                                    secondaryEndpoint: ServerEndpoint(urlString: "https://old-relay.invalid", pinnedCertSHA256: pin))
        for input in ["", "{", #"{"v":2,"mode":"relay","url":"https://relay.invalid"}"#,
                      #"{"v":1,"url":"https://relay.invalid"}"#, #"{"url":"https://relay.invalid","fp":null}"#,
                      #"{"url":"https://relay.invalid","fp":"bad"}"#, "ftp://relay.invalid"] {
            let model = ServerEditorModel(editing: profile)
            model.token = "original-fixture"
            XCTAssertTrue(model.applyPairingCode(#"{"v":1,"mode":"relay","url":"https://relay.invalid","token":"new-fixture"}"#))
            XCTAssertNotNil(model.pendingRelayPairing)
            XCTAssertFalse(model.applyPairingCode(input))
            XCTAssertNotNil(model.scanError)
            XCTAssertNil(model.pendingRelayPairing)
            XCTAssertEqual(model.urlString, profile.urlString)
            XCTAssertEqual(model.name, profile.name)
            XCTAssertEqual(model.token, "original-fixture")
            XCTAssertEqual(model.pinnedCertSHA256, pin)
            XCTAssertEqual(model.pairingMode, "direct")
            XCTAssertEqual(model.secondaryEndpointForSave, profile.secondaryEndpoint)
        }
    }

    func testPastedRelayOffersSecondaryCancelAndPrimaryReplacement() {
        let profile = ServerProfile(name: "LAN", urlString: "http://lan.invalid:3090", pairingMode: "direct",
                                    secondaryEndpoint: ServerEndpoint(urlString: "https://old-relay.invalid"))
        let model = ServerEditorModel(editing: profile, hasExistingToken: true)
        let input = """
        {"v":1,"mode":"relay","url":"https://relay.invalid:18443","token":"relay-fixture","fp":"\(pin)","name":"Relay"}
        """
        XCTAssertTrue(model.applyPairingCode(input))
        XCTAssertEqual(model.urlString, profile.urlString)
        XCTAssertEqual(model.token, "")
        model.cancelRelayImport()
        XCTAssertEqual(model.secondaryEndpointForSave, profile.secondaryEndpoint)
        XCTAssertTrue(model.applyPairingCode(input))
        model.resolveRelayImport(addAsSecondary: true)
        XCTAssertEqual(model.urlString, profile.urlString)
        XCTAssertEqual(model.name, "LAN")
        XCTAssertEqual(model.pairingMode, "direct")
        XCTAssertNil(model.pinnedCertSHA256)
        XCTAssertEqual(model.secondaryURLString, "https://relay.invalid:18443")
        XCTAssertEqual(model.secondaryPinnedCertSHA256, pin)
        XCTAssertEqual(model.token, "relay-fixture")
        XCTAssertEqual(model.testEndpoint, .secondary)
        XCTAssertTrue(model.applyPairingCode(input))
        model.resolveRelayImport(addAsSecondary: false)
        XCTAssertEqual(model.urlString, "https://relay.invalid:18443")
        XCTAssertEqual(model.name, "Relay")
        XCTAssertEqual(model.pairingMode, "relay")
        XCTAssertEqual(model.pinnedCertSHA256, pin)
    }
}
