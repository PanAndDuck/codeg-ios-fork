import XCTest
import Security
@testable import Codeg

@MainActor
final class EndpointMigrationTests: XCTestCase {
    func testLegacyTokenOnlyKeychainItemMigratesAtomically() throws {
        let id = UUID()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.codeg.ios.server-token",
                                    kSecAttrAccount as String: id.uuidString]
        var attributes = query
        attributes[kSecValueData as String] = Data("legacy-test-token".utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            UserDefaults.standard.set("legacy-test-token", forKey: "codeg.token.fallback." + id.uuidString)
        } else { XCTAssertEqual(status, errSecSuccess) }
        #else
        XCTAssertEqual(status, errSecSuccess)
        #endif
        defer { Keychain.deleteToken(for: id) }
        XCTAssertEqual(Keychain.token(for: id), "legacy-test-token")
        XCTAssertEqual(Keychain.credentials(for: id)?.customHeaders, [])
        let headers = [HeaderPair(name: "X-Secret", value: "test-secret")]
        XCTAssertTrue(Keychain.setCredentials(token: "legacy-test-token", customHeaders: headers, for: id))
        XCTAssertEqual(Keychain.credentials(for: id)?.customHeaders, headers)
        XCTAssertEqual(Keychain.token(for: id), "legacy-test-token")
        XCTAssertNil(UserDefaults.standard.string(forKey: "codeg.token.fallback." + id.uuidString))
        let lookup = SecItemCopyMatching(query as CFDictionary, nil)
        XCTAssertTrue(lookup == errSecItemNotFound || lookup == errSecMissingEntitlement)
        XCTAssertTrue(Keychain.setToken("rotated", for: id))
        XCTAssertEqual(Keychain.credentials(for: id)?.customHeaders, headers)
        XCTAssertEqual(Keychain.token(for: id), "rotated")
    }

    func testManualPrimaryRoleIsExplicitAndControlsQRMergeOffer() {
        let editor = ServerEditorModel(editing: ServerProfile(name: "Server", urlString: "https://public.invalid:18443"))
        editor.primaryIsRelay = true
        XCTAssertEqual(editor.pairingMode, "relay")
        XCTAssertTrue(editor.applyScanned(#"{"v":1,"mode":"relay","url":"https://another.invalid:18443"}"#))
        XCTAssertNil(editor.pendingRelayPairing)
        editor.primaryIsRelay = false
        XCTAssertEqual(editor.pairingMode, "direct")
        XCTAssertTrue(editor.applyScanned(#"{"v":1,"mode":"relay","url":"https://third.invalid:18443"}"#))
        XCTAssertNotNil(editor.pendingRelayPairing)
    }
    func testNewEndpointMetadataSurvivesDecodingWithoutPersistingHeaderValues() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"Home","urlString":"http://lan.invalid:3090","createdAt":0,"secondaryEndpoint":{"urlString":"https://relay.invalid:18443","pinnedCertSHA256":null},"customHeaders":[{"name":"CF-Access-Client-Secret","value":"must-not-be-in-defaults"}]}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["secondaryEndpoint"])
        XCTAssertNotNil(object["customHeaders"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("must-not-be-in-defaults"))
    }

    func testRelayImportIntoExistingLANWaitsForMergeChoice() {
        let profile = ServerProfile(name: "Home", urlString: "http://lan.invalid:3090", pairingMode: "direct")
        let editor = ServerEditorModel(editing: profile, hasExistingToken: true)
        XCTAssertTrue(editor.applyScanned(#"{"v":1,"mode":"relay","url":"https://relay.invalid:18443","token":"fixture"}"#))
        XCTAssertEqual(editor.urlString, profile.urlString)
        XCTAssertEqual(editor.name, profile.name)
        XCTAssertEqual(editor.token, "")
        XCTAssertNotNil(editor.pendingRelayPairing)
        editor.resolveRelayImport(addAsSecondary: true)
        XCTAssertEqual(editor.urlString, profile.urlString)
        XCTAssertEqual(editor.secondaryEndpointForSave?.urlString, "https://relay.invalid:18443")
        XCTAssertEqual(editor.token, "fixture")
        XCTAssertNil(editor.pendingRelayPairing)
    }

    func testRelayMergeKeepsIndependentPinsAndCancelDoesNotChangeFields() {
        let primaryPin = String(repeating: "ab", count: 32)
        let relayPin = String(repeating: "cd", count: 32)
        let profile = ServerProfile(name: "Home", urlString: "https://lan.invalid:3090", pinnedCertSHA256: primaryPin, pairingMode: "direct")
        let editor = ServerEditorModel(editing: profile, hasExistingToken: true)
        let qr = "{\"v\":1,\"mode\":\"relay\",\"url\":\"https://relay.invalid:18443\",\"fp\":\"\(relayPin)\"}"
        XCTAssertTrue(editor.applyScanned(qr))
        editor.cancelRelayImport()
        XCTAssertNil(editor.secondaryEndpointForSave)
        XCTAssertEqual(editor.pinnedCertSHA256, primaryPin)
        XCTAssertTrue(editor.applyScanned(qr))
        editor.resolveRelayImport(addAsSecondary: true)
        XCTAssertEqual(editor.pinnedCertSHA256, primaryPin)
        XCTAssertEqual(editor.secondaryEndpointForSave?.pinnedCertSHA256, relayPin)
        editor.secondaryURLString = "http://relay.invalid:18443"
        XCTAssertFalse(editor.canSave)
        XCTAssertFalse(editor.canTest)
    }

    func testRelayOfferCanExplicitlyReplacePrimaryAndNewServersImportDirectly() {
        let profile = ServerProfile(name: "Home", urlString: "http://lan.invalid:3090")
        let editor = ServerEditorModel(editing: profile)
        let qr = #"{"v":1,"mode":"relay","url":"https://relay.invalid:18443","token":"fixture"}"#
        XCTAssertTrue(editor.applyScanned(qr))
        editor.resolveRelayImport(addAsSecondary: false)
        XCTAssertEqual(editor.urlString, "https://relay.invalid:18443")
        XCTAssertEqual(editor.pairingMode, "relay")
        let fresh = ServerEditorModel()
        XCTAssertTrue(fresh.applyScanned(qr))
        XCTAssertNil(fresh.pendingRelayPairing)
        XCTAssertEqual(fresh.urlString, "https://relay.invalid:18443")
    }

    func testStorePersistsSecretsOnlyInKeychainAndPreservesThemOnMetadataEdits() throws {
        let suite = "I6-headers-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        let headers = [HeaderPair(name: "CF-Access-Client-Secret", value: "private-fixture-value")]
        let saved = try XCTUnwrap(store.add(name: "Home", urlString: "http://lan.invalid:3090", token: "private-fixture-token", customHeaders: headers))
        defer { store.delete(saved) }
        let data = try XCTUnwrap(defaults.data(forKey: "codeg.servers.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-fixture"))
        XCTAssertEqual(store.customHeaders(for: saved), headers)
        let reloaded = ServerStore(defaults: defaults)
        var edited = try XCTUnwrap(reloaded.servers.first)
        edited.name = "Renamed"
        XCTAssertTrue(reloaded.update(edited, token: nil))
        XCTAssertEqual(reloaded.customHeaders(for: edited), headers)
        XCTAssertEqual(reloaded.token(for: edited), "private-fixture-token")
        XCTAssertTrue(reloaded.update(edited, token: "rotated", customHeaders: []))
        XCTAssertEqual(reloaded.customHeaders(for: edited), [])
        XCTAssertEqual(reloaded.token(for: edited), "rotated")
    }
}
