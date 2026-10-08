import Foundation
import CryptoKit

enum CertificateFingerprint {
    enum Invalid: LocalizedError {
        case malformed

        var errorDescription: String? {
            "Invalid certificate fingerprint. Expected SHA-256: 64 hexadecimal characters, optionally separated by colons or spaces."
        }
    }

    static func normalize(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sha256/") || value.hasPrefix("sha256:") {
            value.removeFirst(7)
        }
        value = value.filter { $0 != ":" && !$0.isWhitespace }
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Invalid.malformed
        }
        return value
    }

    static func display(_ canonical: String) -> String {
        guard let normalized = try? normalize(canonical) else { return canonical }
        let characters = Array(normalized.uppercased())
        return stride(from: 0, to: characters.count, by: 2)
            .map { String(characters[$0...($0 + 1)]) }.joined(separator: ":")
    }

    static func sha256(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
