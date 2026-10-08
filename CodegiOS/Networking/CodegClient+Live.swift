import Foundation

extension CodegClient {
    /// `false` means the server no longer has this ACP connection.
    @discardableResult
    func touchConnection(connectionId: String) async throws -> Bool {
        try await postJSON("acp_touch_connection", ConnectionIdBody(connectionId: connectionId))
    }

    /// The options projection returned by the existing overload intentionally
    /// omits turn state. Recovery needs the complete live projection.
    func connectionSnapshot(connectionId: String, as type: LiveSessionSnapshot.Type) async throws -> LiveSessionSnapshot? {
        let data = try await send("acp_get_session_snapshot", body: ConnectionIdBody(connectionId: connectionId))
        if Self.isJSONNull(data) { return nil }
        do { return try CodegJSON.decoder.decode(type, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
}
