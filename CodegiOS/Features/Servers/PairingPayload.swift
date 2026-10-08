import Foundation

struct PairingPayload {
    let url: URL
    let token: String?
    let name: String?
    let fingerprint: String?
    let mode: String?

    func shouldOfferSecondary(editing: ServerProfile?, primaryMode: String?, primaryURL: URL?) -> Bool {
        editing != nil && mode == "relay" && primaryMode != "relay"
            && primaryURL != nil && primaryURL != url
    }

    enum Invalid: LocalizedError {
        case payload, version, mode, fingerprintRequiresHTTPS

        var errorDescription: String? {
            switch self {
            case .payload: "That QR code is not a valid codeg server address or pairing payload."
            case .version: "Unsupported pairing QR version. Expected version 1."
            case .mode: "Invalid pairing mode. Expected relay or direct."
            case .fingerprintRequiresHTTPS: "A certificate fingerprint requires an HTTPS server URL."
            }
        }
    }

    private struct JSONPayload: Decodable {
        let v: Int?
        let mode: String?
        let url: String?
        let address: String?
        let server: String?
        let token: String?
        let name: String?
        let fp: String?
    }

    static func parse(_ raw: String) throws -> PairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Invalid.payload }
        var address = trimmed
        var name: String?
        var token: String?
        var fingerprint: String?
        var mode: String?
        if trimmed.hasPrefix("{") {
            let data = Data(trimmed.utf8)
            // A wrong-type/null fingerprint must not silently become no pin.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawPin = object["fp"] {
                guard let string = rawPin as? String else { throw CertificateFingerprint.Invalid.malformed }
                fingerprint = try CertificateFingerprint.normalize(string)
            }
            guard let json = try? JSONDecoder().decode(JSONPayload.self, from: data),
                  let candidate = json.url ?? json.address ?? json.server else { throw Invalid.payload }
            if let version = json.v, version != 1 { throw Invalid.version }
            if let value = json.mode, value != "relay" && value != "direct" { throw Invalid.mode }
            if json.v != nil && json.mode == nil { throw Invalid.mode }
            address = candidate
            name = cleaned(json.name)
            token = cleaned(json.token)
            mode = json.mode
        }
        guard let normalized = ServerEditorModel.normalizedURL(from: address),
              var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else { throw Invalid.payload }
        if let items = components.queryItems {
            token = token ?? cleaned(items.first { $0.name.lowercased() == "token" }?.value)
            let remaining = items.filter { $0.name.lowercased() != "token" }
            components.queryItems = remaining.isEmpty ? nil : remaining
        }
        guard let url = components.url else { throw Invalid.payload }
        guard fingerprint == nil || url.scheme?.lowercased() == "https" else { throw Invalid.fingerprintRequiresHTTPS }
        return PairingPayload(url: url, token: token, name: name, fingerprint: fingerprint, mode: mode)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
