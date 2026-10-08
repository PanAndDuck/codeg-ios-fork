import Foundation

/// A saved codeg server connection. The auth token is NOT stored here — it
/// lives in the Keychain keyed by `id`. Metadata persists in UserDefaults.
struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var urlString: String
    var createdAt: Date
    var pinnedCertSHA256: String? {
        didSet {
            if let value = pinnedCertSHA256, let canonical = try? CertificateFingerprint.normalize(value) {
                pinnedCertSHA256 = canonical
            }
        }
    }
    var pairingMode: String?
    var secondaryEndpoint: ServerEndpoint?
    /// Runtime values are hydrated from Keychain; Codable writes names only.
    var customHeaders: [HeaderPair]
    var credentialsRevision: UUID?

    var primaryEndpoint: ServerEndpoint {
        ServerEndpoint(urlString: urlString, pinnedCertSHA256: pinnedCertSHA256)
    }

    /// Changes to the endpoint or TLS policy must recreate stateful clients.
    var connectionIdentity: String {
        "\(id)|\(urlString)|\(pinnedCertSHA256 ?? "")|\(pairingMode ?? "")|\(secondaryEndpoint?.urlString ?? "")|\(secondaryEndpoint?.pinnedCertSHA256 ?? "")|\(credentialsRevision?.uuidString ?? "")"
    }

    init(id: UUID = UUID(), name: String, urlString: String, createdAt: Date = Date(),
         pinnedCertSHA256: String? = nil, pairingMode: String? = nil,
         secondaryEndpoint: ServerEndpoint? = nil, customHeaders: [HeaderPair] = []) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.createdAt = createdAt
        // Keep malformed non-nil values fail-closed at the trust boundary.
        self.pinnedCertSHA256 = pinnedCertSHA256.map { (try? CertificateFingerprint.normalize($0)) ?? $0 }
        self.pairingMode = pairingMode
        self.secondaryEndpoint = secondaryEndpoint
        self.customHeaders = customHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, urlString, createdAt, pinnedCertSHA256, pairingMode, secondaryEndpoint, customHeaders, credentialsRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        urlString = try values.decode(String.self, forKey: .urlString)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        pinnedCertSHA256 = try values.decodeIfPresent(String.self, forKey: .pinnedCertSHA256)
            .map { try CertificateFingerprint.normalize($0) }
        pairingMode = try values.decodeIfPresent(String.self, forKey: .pairingMode)
        secondaryEndpoint = try values.decodeIfPresent(ServerEndpoint.self, forKey: .secondaryEndpoint)
        customHeaders = try values.decodeIfPresent([HeaderPair].self, forKey: .customHeaders) ?? []
        credentialsRevision = try values.decodeIfPresent(UUID.self, forKey: .credentialsRevision)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(urlString, forKey: .urlString)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(pinnedCertSHA256, forKey: .pinnedCertSHA256)
        try values.encodeIfPresent(pairingMode, forKey: .pairingMode)
        try values.encodeIfPresent(secondaryEndpoint, forKey: .secondaryEndpoint)
        try values.encode(customHeaders.map { HeaderPair(name: $0.name, value: "") }, forKey: .customHeaders)
        try values.encodeIfPresent(credentialsRevision, forKey: .credentialsRevision)
    }

    /// Normalized, validated base URL (`http://host:3080`), or nil if it is not a
    /// safe http(s) endpoint. Rejects non-http(s) schemes, a missing host, and any
    /// embedded userinfo (`user:pass@host`) so the bearer token can never be
    /// directed at an unexpected scheme/host. This is the security boundary used by
    /// `ServerStore.client` and `EventStream`.
    var baseURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        if components.scheme == nil {
            components = URLComponents(string: "http://\(trimmed)") ?? components
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        components.scheme = scheme
        guard pinnedCertSHA256 == nil || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        // Drop a trailing slash path so appendingPathComponent("api") is clean.
        if components.path == "/" { components.path = "" }
        return components.url
    }

    /// Host:port shown in the UI.
    var displayHost: String {
        guard let url = baseURL else { return urlString }
        var host = url.host ?? urlString
        if let port = url.port { host += ":\(port)" }
        return host
    }
}
