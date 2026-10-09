import Foundation
import OSLog

/// Endpoint timing only: never record credentials, headers, bodies or query strings.
enum FailoverDiagnostics {
    private static let logger = Logger(subsystem: "app.codeg.ios.failover", category: "network")

    static func record(_ event: String) {
        logger.info("\(ProcessInfo.processInfo.systemUptime, privacy: .public) \(event, privacy: .public)")
    }
}
