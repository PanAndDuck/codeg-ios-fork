import Foundation

struct HeaderPair: Codable, Hashable, Sendable {
    var name: String
    var value: String
}

enum RequestHeaders {
    private static let reserved: Set<String> = ["authorization", "host", "connection", "upgrade", "content-length"]
    private static let nameCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func isAllowed(_ header: HeaderPair) -> Bool {
        let name = header.name.lowercased()
        return !name.isEmpty && !reserved.contains(name) && !name.hasPrefix("sec-websocket-")
            && header.name.unicodeScalars.allSatisfy { nameCharacters.contains($0) }
            && header.value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 || $0.value == 9 }
    }

    static func validationError(_ headers: [HeaderPair]) -> String? {
        var names = Set<String>()
        for header in headers {
            guard isAllowed(header) else {
                return String(localized: "Use a valid header name and value. Authorization, WebSocket and connection headers are reserved.")
            }
            guard names.insert(header.name.lowercased()).inserted else {
                return String(localized: "Header names must be unique (case insensitive).")
            }
        }
        return nil
    }

    /// Defense in depth: callers outside the editor cannot override transport
    /// headers or inject new header lines. First occurrence wins for duplicates.
    static func apply(_ headers: [HeaderPair], to request: inout URLRequest) {
        var names = Set<String>()
        for header in headers where isAllowed(header) {
            guard names.insert(header.name.lowercased()).inserted else { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
    }
}
