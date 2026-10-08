import Foundation

/// Pure policy. I/O, path observation and stale-probe rejection live in ServerStore.
struct EndpointSelector {
    enum Endpoint: String, Sendable { case primary, secondary }
    enum Source: Hashable, Sendable { case http, webSocket }
    private(set) var choice: Endpoint = .primary
    private(set) var needsProbe = true
    private(set) var failedEndpoint: Endpoint?
    private var failures: [Source: Int] = [:]

    static func decide(onWiFi: Bool, primaryHealthy: Bool, secondaryHealthy: Bool) -> Endpoint? {
        if onWiFi && primaryHealthy { return .primary }
        if secondaryHealthy { return .secondary }
        return primaryHealthy ? .primary : nil
    }

    mutating func trigger() { needsProbe = true; failedEndpoint = nil; failures = [:] }
    mutating func recordConnectivityFailure() {
        failedEndpoint = choice
        needsProbe = true
    }
    mutating func recordSuccess(source: Source = .http) { failures[source] = 0 }
    mutating func recordFailure(source: Source = .http) {
        failures[source, default: 0] += 1
        if failures[source, default: 0] >= 2 { needsProbe = true }
    }
    mutating func accept(onWiFi: Bool, primaryHealthy: Bool, secondaryHealthy: Bool) {
        if failedEndpoint == .primary && secondaryHealthy { choice = .secondary }
        else if failedEndpoint == .secondary && primaryHealthy { choice = .primary }
        else { choice = Self.decide(onWiFi: onWiFi, primaryHealthy: primaryHealthy, secondaryHealthy: secondaryHealthy) ?? choice }
        needsProbe = false
        failedEndpoint = nil
        failures = [:]
    }
}
