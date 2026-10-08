import Foundation

/// A separate origin and trust policy. Credentials belong to the logical server.
struct ServerEndpoint: Codable, Hashable, Sendable {
    var urlString: String
    var pinnedCertSHA256: String?

    init(urlString: String, pinnedCertSHA256: String? = nil) {
        self.urlString = urlString
        self.pinnedCertSHA256 = pinnedCertSHA256.map { (try? CertificateFingerprint.normalize($0)) ?? $0 }
    }

    private enum CodingKeys: String, CodingKey { case urlString, pinnedCertSHA256 }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try values.decode(String.self, forKey: .urlString)
        pinnedCertSHA256 = try values.decodeIfPresent(String.self, forKey: .pinnedCertSHA256)
            .map { try CertificateFingerprint.normalize($0) }
    }

    var baseURL: URL? {
        ServerProfile(name: "", urlString: urlString, pinnedCertSHA256: pinnedCertSHA256).baseURL
    }
}
