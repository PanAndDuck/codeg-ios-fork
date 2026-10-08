import XCTest
@testable import Codeg

final class TrustEvaluatorTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)

    func testFingerprintNormalizationAndDisplay() throws {
        let human = Array(repeating: "AB", count: 32).joined(separator: ":")
        for value in [pin, human, " sha256/\(human) ", "SHA256: \(human)", Array(repeating: "AB", count: 32).joined(separator: " ")] {
            XCTAssertEqual(try CertificateFingerprint.normalize(value), pin)
        }
        XCTAssertEqual(CertificateFingerprint.display(pin), human)
        for invalid in ["", "ab", String(repeating: "g", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 65), "sha256/sha256/\(pin)"] {
            XCTAssertThrowsError(try CertificateFingerprint.normalize(invalid))
        }
    }

    func testSHA256HashesDERBytesRatherThanTextOrPublicKey() {
        XCTAssertEqual(CertificateFingerprint.sha256(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStrictPinDecisionTable() {
        for systemTrusted in [true, false] {
            XCTAssertEqual(TrustEvaluator.decision(pin: pin, presented: pin, systemTrusted: systemTrusted), .accept)
            XCTAssertEqual(TrustEvaluator.decision(pin: pin, presented: String(repeating: "cd", count: 32), systemTrusted: systemTrusted), .reject)
            XCTAssertEqual(TrustEvaluator.decision(pin: pin, presented: nil, systemTrusted: systemTrusted), .reject)
            XCTAssertEqual(TrustEvaluator.decision(pin: "invalid", presented: "invalid", systemTrusted: systemTrusted), .reject)
        }
        XCTAssertEqual(TrustEvaluator.decision(pin: nil, presented: pin, systemTrusted: true), .systemDefault)
        XCTAssertEqual(TrustEvaluator.decision(pin: nil, presented: pin, systemTrusted: false), .recordUntrusted)
    }

    func testSessionCacheReplacesOnlyChangedEndpointOrPin() {
        let factory = SessionFactory()
        var profile = ServerProfile(name: "A", urlString: "https://example.test:18443")
        let original = factory.sessions(for: profile)
        profile.name = "Renamed"
        XCTAssertTrue(original === factory.sessions(for: profile))
        profile.pinnedCertSHA256 = pin
        let pinned = factory.sessions(for: profile)
        XCTAssertFalse(original === pinned)
        XCTAssertTrue(pinned === factory.sessions(for: profile))
        profile.urlString = "https://another.test:18443"
        XCTAssertFalse(pinned === factory.sessions(for: profile))
        let other = ServerProfile(name: "Other", urlString: profile.urlString, pinnedCertSHA256: pin)
        XCTAssertFalse(factory.sessions(for: other) === factory.sessions(for: profile))
        let beforeRemoval = factory.sessions(for: profile)
        factory.invalidate(profile.id)
        XCTAssertFalse(beforeRemoval === factory.sessions(for: profile))
    }

    func testPinnedRedirectCannotDowngradeOrLeaveOrigin() {
        let evaluator = TrustEvaluator(baseURL: URL(string: "https://example.test:18443")!, pin: pin)
        XCTAssertTrue(evaluator.allowsRedirect(to: URL(string: "https://example.test:18443/new")!))
        XCTAssertFalse(evaluator.allowsRedirect(to: URL(string: "http://example.test:18443/new")!))
        XCTAssertFalse(evaluator.allowsRedirect(to: URL(string: "https://other.test:18443")!))
        XCTAssertFalse(evaluator.allowsRedirect(to: URL(string: "https://example.test:18444")!))
    }

    func testProfileStreamFailsFastWhileHTTPStillWaitsForConnectivity() {
        let factory = SessionFactory()
        let profile = ServerProfile(name: "Relay", urlString: "https://example.test:18443", pinnedCertSHA256: pin)
        let sessions = factory.sessions(for: profile)
        let client = CodegClient(baseURL: profile.baseURL!, token: "test-only", sessions: sessions)
        XCTAssertFalse(client.streamSession.configuration.waitsForConnectivity)
        XCTAssertEqual(client.streamSession.configuration.timeoutIntervalForResource, 604_800)
        XCTAssertTrue(client.probeSession.configuration.waitsForConnectivity)
        XCTAssertEqual(client.probeSession.configuration.timeoutIntervalForRequest, 90)
    }
}
