import Foundation

/// Incremental *encoder* for the `text/event-stream` (SSE) wire format — the
/// symmetric outbound counterpart of ``SSEEventDecoder``.
///
/// SSE is asymmetric: a JSON-RPC client receives SSE and only ever *decodes* it,
/// whereas an SSE *server* only ever *produces* it. This type is that producer.
/// Per the SSE spec a single event is a run of `field: value` lines terminated by
/// a blank line; multi-line `data` folds to one `data:` line per `\n`-separated
/// segment, an empty payload is the bare `data:` line, and a `:`-prefixed line is
/// a comment (which is *not* itself an event, so it carries no trailing blank
/// line). The optional `id:` / `retry:` / `event:` lines precede the `data:` lines.
///
/// `Data` in/out (not `String`) mirrors ``SSEEventDecoder`` and the byte-oriented
/// transports the frames are written to. The type is a pure, stateless value.
public struct SSEEventEncoder: Sendable {
    public init() {}

    /// Encode one SSE `data` event.
    ///
    /// - Parameters:
    ///   - data: The payload. Each `\n`-separated segment becomes its own
    ///     `data: <segment>` line; an empty string yields a single bare `data:`
    ///     line (so the client dispatches an event with empty data).
    ///   - event: Optional `event:` name.
    ///   - id: Optional `id:` (the resumption anchor a client echoes as
    ///     `Last-Event-ID`).
    ///   - retry: Optional `retry:` reconnection hint in milliseconds.
    /// - Returns: The event's bytes, terminated by the dispatching blank line.
    public func encode(data: String, event: String? = nil, id: String? = nil, retry: Int? = nil) -> Data {
        var message = ""
        if let id { message += "id: \(id)\n" }
        if let retry { message += "retry: \(retry)\n" }
        if let event { message += "event: \(event)\n" }
        if data.isEmpty {
            message += "data:\n"
        } else {
            for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
                message += "data: \(line)\n"
            }
        }
        message += "\n"
        return Data(message.utf8)
    }

    /// Encode an SSE comment line: `: <text>\n`. A comment keeps a connection warm
    /// without dispatching an event, so it has no trailing blank line.
    public func comment(_ text: String) -> Data {
        Data(": \(text)\n".utf8)
    }
}
