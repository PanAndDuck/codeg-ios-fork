import SwiftUI
import Observation

/// Drives the Add / Edit Server sheet: holds the editable fields, validates
/// them, and runs the standalone "Test Connection" probe against a throwaway
/// `CodegClient` built from the entered values.
@MainActor
@Observable
final class ServerEditorModel {
    /// Result of a "Test Connection" attempt, shown inline beneath the button.
    enum TestResult: Equatable {
        case success(version: String)
        case failure(message: String)
        case certificate(fingerprint: String, isMismatch: Bool)
    }

    // Editable fields
    var name: String
    var urlString: String { didSet { fieldsChanged() } }
    var token: String { didSet { fieldsChanged() } }
    private(set) var pinnedCertSHA256: String?
    private(set) var pairingMode: String?
    private(set) var scanError: String?
    private let probeID = UUID()
    private let sessionFactory = SessionFactory()

    private(set) var isTesting = false
    private(set) var testResult: TestResult?

    /// The profile being edited, or nil when adding.
    let editing: ServerProfile?
    /// Whether a token is already stored for the edited profile. When true the
    /// token field may be left blank to keep the existing secret.
    let hasExistingToken: Bool
    /// Resolves the token already stored for the edited profile, read lazily (from
    /// the Keychain) only when needed so the secret is never held in editor state.
    /// Lets Test Connection probe with the existing token when the field is blank.
    private let resolveExistingToken: @MainActor () -> String?

    var isEditMode: Bool { editing != nil }
    var title: LocalizedStringKey { isEditMode ? "Edit Server" : "Add Server" }
    var saveButtonTitle: String { isEditMode ? "Save Changes" : "Add Server" }

    init(
        editing: ServerProfile? = nil,
        hasExistingToken: Bool = false,
        resolveExistingToken: @escaping @MainActor () -> String? = { nil }
    ) {
        self.editing = editing
        self.name = editing?.name ?? ""
        self.urlString = editing?.urlString ?? ""
        self.pinnedCertSHA256 = editing?.pinnedCertSHA256
        self.pairingMode = editing?.pairingMode
        self.hasExistingToken = editing != nil && hasExistingToken
        self.resolveExistingToken = resolveExistingToken
        // The token secret is never loaded into editable state. An empty field
        // on save means "keep the existing token" (only valid when one exists).
        self.token = ""
    }

    // MARK: - Validation

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The token with surrounding whitespace/newlines stripped — what actually
    /// gets validated and persisted (a paste often carries a trailing newline).
    var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A *usable* normalized base URL derived from the entered string, or nil if
    /// it can't form a real `http`/`https` endpoint.
    ///
    /// `ServerProfile.baseURL` alone is too permissive — it returns non-nil for
    /// inputs `CodegClient` can't actually reach (e.g. an empty string becomes
    /// `http://` with no host, and a bare `host:port` like `localhost:3080`
    /// parses as scheme `localhost` with no host). We coerce a bare authority to
    /// `http://…` and require a concrete scheme + host so Save/Test only enable
    /// for an address that will resolve, and so the persisted string round-trips
    /// cleanly back through `ServerProfile.baseURL`.
    var parsedBaseURL: URL? {
        guard let url = Self.normalizedURL(from: urlString),
              pinnedCertSHA256 == nil || url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// The string to persist: the normalized absolute URL when available so the
    /// stored profile is always usable, else the trimmed raw input.
    var urlStringForSave: String {
        parsedBaseURL?.absoluteString ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a blank token field is allowed to keep the existing stored secret:
    /// whenever one is already stored. The endpoint is intentionally not a factor
    /// — editing a server's address (e.g. it moved to a new IP) keeps the token
    /// the user already entered rather than forcing a re-paste.
    var canKeepExistingToken: Bool { hasExistingToken }

    /// Save is allowed once a name and a usable URL are present, plus a token —
    /// unless an existing token can be kept (blank field while one is already
    /// stored).
    var canSave: Bool {
        guard !trimmedName.isEmpty, parsedBaseURL != nil else { return false }
        return !trimmedToken.isEmpty || canKeepExistingToken
    }

    /// Footer copy under the token field: when a token is already stored, a blank
    /// field keeps it; otherwise one must be entered.
    var authFooter: LocalizedStringKey {
        if hasExistingToken {
            return "Leave blank to keep the existing token."
        }
        return "The bearer token issued by your codeg server."
    }

    /// Placeholder for the token field — only promises to keep the existing token
    /// when that is actually possible (same endpoint).
    var tokenPlaceholder: LocalizedStringKey {
        canKeepExistingToken ? "Keep existing token" : "Paste token"
    }

    /// The token to persist on save: the freshly entered (trimmed) one, or `nil`
    /// to keep the existing stored token untouched.
    var tokenForSave: String? {
        trimmedToken.isEmpty ? nil : trimmedToken
    }

    /// Whether the Test Connection probe can run: needs a usable URL plus a token
    /// to send — either freshly entered, or the existing stored one when editing
    /// with the field left blank (so "keep existing" can still be verified).
    var canTest: Bool {
        guard parsedBaseURL != nil else { return false }
        return !trimmedToken.isEmpty || canKeepExistingToken
    }

    /// Coerce a user-entered address into a reachable `http`/`https` URL, or nil.
    ///
    /// Mirrors `ServerProfile.baseURL`'s scheme-prefixing but tightens it for
    /// production input:
    /// - An explicit `scheme://` is honored only when it is `http`/`https`; any
    ///   other scheme (`ftp://`, `ssh://`, `file://`, …) is rejected rather than
    ///   silently rewritten to `http://<scheme>://…` (which would derive an
    ///   unintended host and leak the bearer token to it).
    /// - A bare authority (`host`, `host:port`) defaults to `http://`.
    /// - The result must have an `http`/`https` scheme, a non-empty host, and —
    ///   if present — a port within the valid TCP range.
    /// - Embedded userinfo (`user:pass@host`) is rejected: such inputs derive
    ///   the effective host from the authority and could send the bearer token
    ///   to an unintended host.
    nonisolated static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        let hadExplicitScheme: Bool
        if let schemeRange = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            // Has an explicit "scheme://": only http/https may pass through.
            let schemeEnd = trimmed.index(schemeRange.upperBound, offsetBy: -3) // drop "://"
            let scheme = trimmed[trimmed.startIndex..<schemeEnd].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            candidate = trimmed
            hadExplicitScheme = true
        } else {
            candidate = "http://\(trimmed)"
            hadExplicitScheme = false
        }

        guard var components = URLComponents(string: candidate) else { return nil }
        if components.path == "/" { components.path = "" }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        // Reject embedded credentials — the token must only reach the host the
        // user actually typed, not one extracted from `user:pass@host`.
        guard components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        // A bare authority typed without a scheme or port (e.g. "192.168.1.10")
        // almost certainly means a codeg server, so default to its standard port
        // (3080) instead of the scheme's implicit :80. An explicit scheme or port
        // is always honored as-is.
        if !hadExplicitScheme, components.port == nil {
            components.port = 3080
        }
        return components.url
    }

    // MARK: - Test Connection

    /// Build a temporary client from the entered values and probe `health()`.
    ///
    /// The URL + token are snapshotted up front; if either changes while the
    /// request is in flight the result is discarded, so a stale probe can't
    /// display a success/failure that no longer matches the visible fields.
    func testConnection() async {
        guard !isTesting else { return }
        guard let baseURL = parsedBaseURL else {
            testResult = .failure(message: APIError.invalidURL.localizedDescription)
            return
        }
        // Send the entered token, or fall back to the stored one when the field
        // is left blank on an edit — that's what a blank-field save would use, so
        // the test exercises the same credentials. `probedToken` snapshots the
        // *field* (not the resolved token) for the staleness check below.
        let probedURL = urlString
        let probedToken = trimmedToken
        let probedPin = pinnedCertSHA256
        let tokenToSend = trimmedToken.isEmpty ? (resolveExistingToken() ?? "") : trimmedToken

        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let profile = ServerProfile(id: probeID, name: name, urlString: baseURL.absoluteString,
                                    pinnedCertSHA256: probedPin)
        let client = CodegClient(baseURL: baseURL, token: tokenToSend, sessions: sessionFactory.sessions(for: profile))
        let result: TestResult
        do {
            let health = try await client.health()
            result = .success(version: health.version)
        } catch APIError.untrustedCertificate(let fingerprint) {
            result = .certificate(fingerprint: fingerprint, isMismatch: probedPin != nil)
        } catch {
            result = .failure(message: error.localizedDescription)
        }

        // Only surface the result if the fields it was computed from still hold;
        // otherwise drop it (a newer edit invalidated this probe). `isTesting`
        // is always cleared via the defer above.
        guard probedURL == urlString, probedToken == trimmedToken, probedPin == pinnedCertSHA256 else { return }
        testResult = result
    }

    /// Clear a stale test result when the user edits a field.
    func fieldsChanged() {
        if testResult != nil { testResult = nil }
    }

    /// Stage an explicitly accepted certificate with the other editable fields.
    /// Replacements require the separate confirmation presented by the sheet.
    @discardableResult
    func trustPresentedCertificate(replacingPin: Bool = false) -> Bool {
        guard case .certificate(let fingerprint, let isMismatch) = testResult,
              !isMismatch || replacingPin,
              let canonical = try? CertificateFingerprint.normalize(fingerprint) else { return false }
        pinnedCertSHA256 = canonical
        sessionFactory.invalidate(probeID)
        fieldsChanged()
        return true
    }

    // MARK: - QR scan

    /// Parse fully before applying, so a bad fingerprint never leaves a partly
    /// imported endpoint/token. A QR replaces the trust metadata along with URL.
    @discardableResult
    func applyScanned(_ raw: String) -> Bool {
        do {
            let pairing = try PairingPayload.parse(raw)
            urlString = pairing.url.absoluteString
            if let name = pairing.name { self.name = name }
            if let token = pairing.token { self.token = token }
            pinnedCertSHA256 = pairing.fingerprint
            pairingMode = pairing.mode
            scanError = nil
            fieldsChanged()
            return true
        } catch {
            scanError = error.localizedDescription
            return false
        }
    }
}
