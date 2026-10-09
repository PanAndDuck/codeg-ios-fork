import Foundation
import Observation

/// Observable store of saved server profiles. Owns persistence (UserDefaults
/// for metadata, Keychain for tokens) and vends `CodegClient`s. Main-actor
/// isolated since it backs SwiftUI state.
@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [ServerProfile]
    private(set) var activeEndpoints: [UUID: EndpointSelector.Endpoint] = [:]

    private let defaults: UserDefaults
    private let storageKey = "codeg.servers.v1"
    private let endpointProbe: EndpointProbe.Operation
    @ObservationIgnored private var transports: [UUID: ConnectionTransport] = [:]
    @ObservationIgnored private var selectors: [UUID: EndpointSelector] = [:]
    @ObservationIgnored private var probeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var probeGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private var networkObservation: NetworkMonitor.Observation?
    @ObservationIgnored private var onWiFi = false

    init(defaults: UserDefaults = .standard, endpointProbe: @escaping EndpointProbe.Operation = { endpoint, token, headers, timeout in
        await EndpointProbe.check(endpoint, token: token, headers: headers, timeout: timeout)
    }) {
        self.defaults = defaults
        self.endpointProbe = endpointProbe
        self.servers = ServerStore.load(from: defaults, key: storageKey)
    }

    // MARK: - Mutations

    /// Add a new server. Returns the created profile, or `nil` if the token
    /// could not be persisted securely — in which case nothing is added, so the
    /// list never holds a server whose token silently failed to save.
    @discardableResult
    func add(name: String, urlString: String, token: String,
             pinnedCertSHA256: String? = nil, pairingMode: String? = nil,
             secondaryEndpoint: ServerEndpoint? = nil, customHeaders: [HeaderPair] = []) -> ServerProfile? {
        let profile = ServerProfile(name: name, urlString: urlString,
                                    pinnedCertSHA256: pinnedCertSHA256, pairingMode: pairingMode,
                                    secondaryEndpoint: secondaryEndpoint,
                                    customHeaders: customHeaders.map { HeaderPair(name: $0.name, value: "") })
        guard RequestHeaders.validationError(customHeaders) == nil,
              Keychain.setCredentials(token: token, customHeaders: customHeaders, for: profile.id) else { return nil }
        servers.append(profile)
        persist()
        if networkObservation != nil { scheduleSelection(profile.id) }
        return profile
    }

    /// Update a server's metadata and, if `token` is non-empty, its secret.
    /// A nil/empty `token` means "keep the existing token unchanged" — including
    /// when the endpoint changed, since editing a server's address (e.g. it moved
    /// to a new IP) shouldn't force the user to re-paste a token they want to
    /// reuse. Returns `false` (and leaves the stored profile untouched) when a
    /// provided token fails to persist, so we never bind new host metadata to a
    /// lost token.
    @discardableResult
    func update(_ profile: ServerProfile, token: String?, customHeaders: [HeaderPair]? = nil) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return false }
        let existing = Keychain.credentials(for: profile.id)
        let nextToken = token.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.token ?? ""
        let headers = customHeaders ?? existing?.customHeaders ?? []
        guard RequestHeaders.validationError(headers) == nil,
              Keychain.setCredentials(token: nextToken, customHeaders: headers, for: profile.id) else { return false }
        var profile = profile
        profile.customHeaders = headers.map { HeaderPair(name: $0.name, value: "") }
        if nextToken != existing?.token || headers != existing?.customHeaders {
            profile.credentialsRevision = UUID()
        }
        let changed = servers[index].connectionIdentity != profile.connectionIdentity
        servers[index] = profile
        if changed {
            resetSelection(profile.id)
            replaceTransport(for: profile, choice: .primary)
            if networkObservation != nil { scheduleSelection(profile.id) }
        }
        persist()
        return true
    }

    func delete(_ profile: ServerProfile) {
        removeConnection(profile.id)
        servers.removeAll { $0.id == profile.id }
        Keychain.deleteToken(for: profile.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            removeConnection(servers[index].id)
            Keychain.deleteToken(for: servers[index].id)
        }
        servers.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Access

    func token(for profile: ServerProfile) -> String? {
        Keychain.token(for: profile.id)
    }

    func customHeaders(for profile: ServerProfile) -> [HeaderPair] {
        Keychain.credentials(for: profile.id)?.customHeaders ?? []
    }

    /// Build an HTTP client for a profile, or nil if the URL/token is missing.
    func client(for profile: ServerProfile) -> CodegClient? {
        guard let saved = servers.first(where: { $0.id == profile.id }) else { return nil }
        if let transport = transports[saved.id] { return CodegClient(transport: transport) }
        let endpoint = activeEndpoint(for: saved)
        guard let baseURL = endpoint.baseURL, let token = token(for: saved) else { return nil }
        let transport = ConnectionTransport(baseURL: baseURL, token: token, customHeaders: customHeaders(for: saved),
                                            sessions: sessions(for: saved, endpoint: endpoint),
                                            onConnectivityFailure: { [weak self] generation, source in
            await self?.recoverConnectivity(id: saved.id, generation: generation, source: source)
        }) { [weak self] generation, source, success in
            Task { @MainActor [weak self] in
                self?.recordOutcome(id: saved.id, generation: generation, source: source, success: success)
            }
        }
        transports[saved.id] = transport
        return CodegClient(transport: transport)
    }

    func activeEndpoint(for profile: ServerProfile) -> ServerEndpoint {
        activeEndpoints[profile.id] == .secondary ? profile.secondaryEndpoint ?? profile.primaryEndpoint : profile.primaryEndpoint
    }

    func endpointLabel(for profile: ServerProfile) -> String {
        activeEndpoints[profile.id] == .secondary || profile.pairingMode == "relay" ? "Relay" : "LAN"
    }

    // MARK: - Endpoint selection

    func startEndpointMonitoring() {
        guard networkObservation == nil else { return }
        networkObservation = NetworkMonitor.shared.observe { [weak self] old, new in
            Task { @MainActor [weak self] in self?.networkDidChange(old: old, new: new) }
        }
        for profile in servers { scheduleSelection(profile.id) }
    }

    func networkDidChange(old: NetworkMonitor.Snapshot?, new: NetworkMonitor.Snapshot) {
        onWiFi = new.status == .satisfied && new.primaryInterface == .wifi
        guard old == nil || NetworkMonitor.isMeaningfulChange(old: old, new: new) else { return }
        for profile in servers { scheduleSelection(profile.id, force: true) }
    }

    /// Status/UI readers await an already-running selection, or reuse its cache.
    func prepareEndpoint(for profile: ServerProfile) async {
        scheduleSelection(profile.id)
        await probeTasks[profile.id]?.value
    }

    private func scheduleSelection(_ id: UUID, force: Bool = false) {
        guard let profile = servers.first(where: { $0.id == id }),
              let secondary = profile.secondaryEndpoint, let token = token(for: profile) else { return }
        if force {
            probeTasks[id]?.cancel()
            probeTasks[id] = nil
            selectors[id, default: EndpointSelector()].trigger()
        }
        guard probeTasks[id] == nil, selectors[id, default: EndpointSelector()].needsProbe else { return }
        let generation = UUID()
        FailoverDiagnostics.record("selection start generation=\(generation)")
        probeGenerations[id] = generation
        let headers = customHeaders(for: profile)
        let wifi = onWiFi
        let probe = endpointProbe
        probeTasks[id] = Task { [weak self] in
            async let primaryHealthy = probe(profile.primaryEndpoint, token, headers, profile.pairingMode == "relay" ? 5 : 1.5)
            async let secondaryHealthy = probe(secondary, token, headers, 5)
            let results = await (primaryHealthy, secondaryHealthy)
            guard !Task.isCancelled, let self, self.probeGenerations[id] == generation,
                  self.servers.contains(where: { $0.id == id && $0.connectionIdentity == profile.connectionIdentity }) else { return }
            self.probeTasks[id] = nil
            let retryGeneration = self.selectors[id]?.failedEndpoint != nil ? self.transports[id]?.snapshot.generation : nil
            self.selectors[id, default: EndpointSelector()].accept(onWiFi: wifi, primaryHealthy: results.0, secondaryHealthy: results.1)
            let choice = self.selectors[id]?.choice ?? .primary
            FailoverDiagnostics.record("selection result primary=\(results.0) secondary=\(results.1) choice=\(choice.rawValue)")
            let oldChoice = self.activeEndpoints[id] ?? .primary
            self.activeEndpoints[id] = choice
            if choice != oldChoice { self.replaceTransport(for: profile, choice: choice, retryFromGeneration: retryGeneration) }
        }
    }

    private func recoverConnectivity(id: UUID, generation: UUID, source: EndpointSelector.Source) async {
        guard transports[id]?.isCurrent(generation) == true,
              servers.first(where: { $0.id == id })?.secondaryEndpoint != nil else { return }
        FailoverDiagnostics.record("connectivity failure generation=\(generation) source=\(source)")
        // The first failure supersedes a startup/path probe; concurrent failures
        // from this generation join the same new selection instead of restarting it.
        if selectors[id]?.failedEndpoint == nil {
            probeTasks.removeValue(forKey: id)?.cancel()
            selectors[id, default: EndpointSelector()].recordConnectivityFailure()
            scheduleSelection(id)
        }
        await probeTasks[id]?.value
    }

    private func recordOutcome(id: UUID, generation: UUID, source: EndpointSelector.Source, success: Bool) {
        FailoverDiagnostics.record("outcome generation=\(generation) source=\(source) success=\(success)")
        guard transports[id]?.isCurrent(generation) == true else { return }
        if success { selectors[id, default: EndpointSelector()].recordSuccess(source: source) }
        else { selectors[id, default: EndpointSelector()].recordFailure(source: source) }
        if !success { scheduleSelection(id) }
    }

    private func replaceTransport(for profile: ServerProfile, choice: EndpointSelector.Endpoint,
                                  retryFromGeneration: UUID? = nil) {
        guard let transport = transports[profile.id] else { return }
        let endpoint = choice == .secondary ? profile.secondaryEndpoint ?? profile.primaryEndpoint : profile.primaryEndpoint
        guard let baseURL = endpoint.baseURL, let token = token(for: profile) else { transport.invalidate(); return }
        transport.replace(baseURL: baseURL, token: token, customHeaders: customHeaders(for: profile),
                          sessions: sessions(for: profile, endpoint: endpoint), retryFromGeneration: retryFromGeneration)
    }

    private func sessions(for profile: ServerProfile, endpoint: ServerEndpoint) -> SessionFactory.Sessions {
        let isLAN = endpoint == profile.primaryEndpoint && profile.pairingMode != "relay"
        let timeout: TimeInterval? = profile.secondaryEndpoint == nil ? nil : (isLAN ? 1.5 : 5)
        return .init(baseURL: endpoint.baseURL!, pin: endpoint.pinnedCertSHA256, connectionTimeout: timeout)
    }

    private func resetSelection(_ id: UUID) {
        probeTasks.removeValue(forKey: id)?.cancel()
        probeGenerations.removeValue(forKey: id)
        selectors.removeValue(forKey: id)
        activeEndpoints.removeValue(forKey: id)
    }

    private func removeConnection(_ id: UUID) {
        resetSelection(id)
        transports.removeValue(forKey: id)?.invalidate()
    }

    deinit {
        networkObservation?.cancel()
        probeTasks.values.forEach { $0.cancel() }
        transports.values.forEach { $0.invalidate() }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [ServerProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
