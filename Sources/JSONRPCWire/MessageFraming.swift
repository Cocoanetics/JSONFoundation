import Foundation

/// How JSON-RPC message bodies are delimited on a byte stream.
///
/// This is the *one* axis on which LSP, ACP, and MCP-over-stdio actually differ:
/// LSP uses HTTP-style `Content-Length` headers; ACP and MCP use one
/// newline-terminated JSON line. Everything else about a stdio transport is
/// identical, so making framing pluggable is what lets a single
/// `StdioTransport` serve all three.
///
/// `frame(_:)` is pure (body → bytes-on-wire). Decoding is stateful — bytes arrive
/// without respecting message boundaries — so a transport keeps its own *value
/// copy* of the framing and feeds it via `push(_:)`; the copy carries the buffer.
public protocol MessageFraming: Sendable {
    /// Wrap one message body for the wire (prepend a header / append a terminator).
    func frame(_ body: Data) -> Data
    /// Feed newly-read bytes, handing each complete message body (header/terminator
    /// stripped) to `emit` as it is decoded, and buffering any partial remainder.
    ///
    /// Throws ``FramingError`` when the bytes cannot yield further messages — a peer
    /// sending more than the configured limit, say. Such a stream cannot be
    /// resynchronised, so a transport answers by finishing its inbound stream with the
    /// error rather than reading on.
    ///
    /// Delivery is a callback rather than a return value precisely because of that
    /// throw: one read can carry a complete message *and* an oversized one, and the
    /// complete message has already been emitted by the time the failure is reported.
    mutating func push(_ bytes: Data, emit: (Data) -> Void) throws
}

extension MessageFraming {
    /// Collects into an array instead of emitting. A failure discards whatever the same
    /// call had already decoded, so transports should prefer the emitting form; this is
    /// for callers that treat any framing failure as fatal.
    public mutating func push(_ bytes: Data) throws -> [Data] {
        var messages: [Data] = []
        try push(bytes) { messages.append($0) }
        return messages
    }
}

/// Why a framing could not turn the bytes it was given into messages.
public enum FramingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// One message exceeded the framing's `maxBytes`. `pending` is how many bytes had
    /// accumulated when the limit was passed — for an unterminated flood that is what
    /// arrived before the buffer was dropped, not the message's real size, which is
    /// unknowable.
    case messageTooLarge(limit: Int, pending: Int)

    public var description: String {
        switch self {
        case .messageTooLarge(let limit, let pending):
            return "Message exceeded the \(limit)-byte framing limit (\(pending) bytes buffered)."
        }
    }
}

/// LSP base-protocol framing: `Content-Length: <n>\r\n\r\n<n bytes of JSON>`.
///
/// Lenient on receipt: only `Content-Length` is required, other headers are
/// ignored, and the body length is counted in bytes (frames may split mid-UTF-8).
public struct ContentLengthFraming: MessageFraming {
    private var buffer = Data()
    private var expectedLength: Int?
    /// Largest single message to accept, in bytes; `0` (the default) is unlimited.
    ///
    /// A declared `Content-Length` is checked *before* its body is buffered, so an
    /// oversized message costs nothing but its header.
    public let maxBytes: Int

    public init(maxBytes: Int = 0) {
        self.maxBytes = maxBytes
    }

    public func frame(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    public mutating func push(_ bytes: Data, emit: (Data) -> Void) throws {
        buffer.append(bytes)
        while let message = try next() { emit(message) }
        // Headers with no separator in sight would otherwise buffer without bound. This
        // is *not* `maxBytes`: that limits a message body, while a read can split
        // anywhere — including part-way through a header longer than a small body limit.
        if expectedLength == nil, buffer.count > Self.maxHeaderBytes {
            throw drop(pending: buffer.count)
        }
    }

    /// How much unterminated header to tolerate. Generous next to any real header, and
    /// independent of `maxBytes` so a small body limit never rejects a legal header that
    /// a read happened to split.
    private static let maxHeaderBytes = 8 * 1024

    private mutating func drop(pending: Int) -> FramingError {
        buffer.removeAll(keepingCapacity: false)
        expectedLength = nil
        return FramingError.messageTooLarge(limit: maxBytes, pending: pending)
    }

    private mutating func next() throws -> Data? {
        if let length = expectedLength {
            guard buffer.count >= length else { return nil }
            let body = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            expectedLength = nil
            return body
        }
        guard let separator = buffer.range(of: Self.headerSeparator) else { return nil }
        let headerBytes = buffer[buffer.startIndex ..< separator.lowerBound]
        let length = Self.contentLength(in: headerBytes)
        buffer.removeSubrange(buffer.startIndex ..< separator.upperBound)
        guard let length else { return try next() }
        // Checked before the body arrives: the header already says how big it is.
        if maxBytes > 0, length > maxBytes { throw drop(pending: length) }
        expectedLength = length
        return try next()
    }

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    private static func contentLength(in header: some DataProtocol) -> Int? {
        guard let text = String(bytes: header, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare("Content-Length") == .orderedSame
            else { continue }
            // Reject a non-numeric or negative length — a bad header must never
            // become a frame size (`buffer.prefix(negative)` would trap).
            guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  length >= 0 else { return nil }
            return length
        }
        return nil
    }
}

/// Newline-delimited JSON framing (ACP and MCP-over-stdio): `<json>\n`.
public struct LineFraming: MessageFraming {
    private var buffer = Data()
    /// Largest single message to accept, in bytes; `0` (the default) is unlimited.
    ///
    /// Newline framing cannot know a message's size in advance, so the limit is
    /// applied twice: to a completed line, and to an unterminated remainder that has
    /// already passed it — which is what stops a peer that never sends a newline from
    /// growing the buffer without bound.
    public let maxBytes: Int

    public init(maxBytes: Int = 0) {
        self.maxBytes = maxBytes
    }

    public func frame(_ body: Data) -> Data {
        var out = body
        out.append(0x0A) // newline terminator
        return out
    }

    public mutating func push(_ bytes: Data, emit: (Data) -> Void) throws {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            let size = line.count
            buffer.removeSubrange(buffer.startIndex ... newline)
            // Emitted before the check on the *next* line, so a message that arrived in
            // the same read as an oversized one is still delivered.
            if maxBytes > 0, size > maxBytes { throw drop(pending: size) }
            if !line.isEmpty { emit(Data(line)) }
        }
        if maxBytes > 0, buffer.count > maxBytes { throw drop(pending: buffer.count) }
    }

    private mutating func drop(pending: Int) -> FramingError {
        buffer.removeAll(keepingCapacity: false)
        return FramingError.messageTooLarge(limit: maxBytes, pending: pending)
    }
}
