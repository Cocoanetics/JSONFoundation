import Foundation
import JSONRPCWire
import Testing

private func body(_ string: String) -> Data { Data(string.utf8) }
private func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

// MARK: - ContentLengthFraming

@Test func contentLengthRoundTripsOneMessage() throws {
    var framing = ContentLengthFraming()
    let out = try framing.push(framing.frame(body(#"{"jsonrpc":"2.0","id":1}"#)))
    #expect(out.count == 1)
    #expect(text(out[0]) == #"{"jsonrpc":"2.0","id":1}"#)
}

@Test func contentLengthSplitsTwoMessagesInOneChunk() throws {
    var framing = ContentLengthFraming()
    let chunk = framing.frame(body(#"{"a":1}"#)) + framing.frame(body(#"{"b":2}"#))
    let out = try framing.push(chunk)
    #expect(out.count == 2)
    #expect(text(out[1]) == #"{"b":2}"#)
}

@Test func contentLengthReassemblesAcrossChunks() throws {
    var framing = ContentLengthFraming()
    var emitted: [Data] = []
    for byte in framing.frame(body(#"{"hello":"world"}"#)) { emitted += try framing.push(Data([byte])) }
    #expect(emitted.count == 1)
    #expect(text(emitted[0]) == #"{"hello":"world"}"#)
}

@Test func contentLengthCountsBytesNotCharacters() throws {
    var framing = ContentLengthFraming()
    let out = try framing.push(framing.frame(body(#"{"v":"café"}"#))) // 5 UTF-8 bytes, 4 chars
    #expect(out.count == 1)
    #expect(text(out[0]) == #"{"v":"café"}"#)
}

@Test func contentLengthRejectsNegativeLength() throws {
    // A malformed `Content-Length: -1` must be dropped, not used as a frame size.
    var framing = ContentLengthFraming()
    let out = try framing.push(Data("Content-Length: -1\r\n\r\n{}".utf8))
    #expect(out.isEmpty)
}

// MARK: - LineFraming

@Test func lineFramingAppendsNewline() {
    #expect(LineFraming().frame(body(#"{"id":1}"#)).last == 0x0A)
}

@Test func lineFramingSplitsMultipleLines() throws {
    var framing = LineFraming()
    let chunk = framing.frame(body(#"{"a":1}"#)) + framing.frame(body(#"{"b":2}"#))
    let out = try framing.push(chunk)
    #expect(out.count == 2)
    #expect(text(out[0]) == #"{"a":1}"#)
}

@Test func lineFramingReassemblesAcrossChunks() throws {
    var framing = LineFraming()
    var emitted: [Data] = []
    for byte in framing.frame(body(#"{"x":42}"#)) { emitted += try framing.push(Data([byte])) }
    #expect(emitted.count == 1)
    #expect(text(emitted[0]) == #"{"x":42}"#)
}

// MARK: - SSEEventDecoder

@Test func sseDecodesOneEvent() throws {
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body("data: {\"id\":1}\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"id\":1}")
}

@Test func sseIgnoresCommentsAndNonDataFields() throws {
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body(": keep-alive\nevent: message\nid: 7\ndata: {\"x\":1}\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"x\":1}")
}

@Test func sseDecodesTwoEventsInOneChunk() throws {
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"))
    #expect(out.count == 2)
    #expect(text(out[1]) == "{\"b\":2}")
}

@Test func sseToleratesCRLF() throws {
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body("data: {\"id\":5}\r\n\r\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"id\":5}")
}

@Test func sseJoinsMultipleDataLines() throws {
    // Doc-promised: multiple `data:` lines of one event join with "\n".
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body("data: {\"a\":\ndata: 1}\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"a\":\n1}")
}

@Test func sseReassemblesAcrossChunks() throws {
    // The SSE path is the one that actually sees arbitrary network chunking.
    var decoder = SSEEventDecoder()
    var emitted: [Data] = []
    for byte in body("data: {\"id\":9}\n\n") { emitted += try decoder.push(Data([byte])) }
    #expect(emitted.count == 1)
    #expect(text(emitted[0]) == "{\"id\":9}")
}

@Test func sseTreatsBareFieldNameAsEmptyValue() throws {
    // Doc-promised: a line with no colon is a field name with an empty value, so
    // a bare `data` line contributes an empty payload — still a dispatched event.
    var decoder = SSEEventDecoder()
    let out = try decoder.push(body("data\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "")
}

// MARK: - Byte limits

@Test func lineFramingIsUnlimitedByDefault() throws {
    var framing = LineFraming()
    let huge = body(String(repeating: "x", count: 1 << 20))
    #expect(try framing.push(framing.frame(huge)).count == 1)
}

@Test func lineFramingRejectsAnOversizedMessage() throws {
    var framing = LineFraming(maxBytes: 16)
    #expect(throws: FramingError.messageTooLarge(limit: 16, pending: 32)) {
        try framing.push(framing.frame(body(String(repeating: "x", count: 32))))
    }
    // The buffer is dropped, so the framing does not keep answering with the failure.
    #expect(try framing.push(framing.frame(body("{}"))).count == 1)
}

/// The case a limit exists for: a peer that never terminates its line would otherwise
/// grow the buffer without bound.
@Test func lineFramingRejectsAnUnterminatedFlood() throws {
    var framing = LineFraming(maxBytes: 8)
    #expect(try framing.push(body("12345")).isEmpty)
    #expect(throws: FramingError.messageTooLarge(limit: 8, pending: 10)) {
        try framing.push(body("67890"))
    }
}

@Test func lineFramingAcceptsAMessageExactlyAtTheLimit() throws {
    var framing = LineFraming(maxBytes: 4)
    let out = try framing.push(framing.frame(body("abcd")))
    #expect(text(out.first ?? Data()) == "abcd")
}

@Test func contentLengthRejectsByTheDeclaredLengthBeforeTheBody() throws {
    var framing = ContentLengthFraming(maxBytes: 16)
    // Only the header is fed: the length alone is enough to refuse it.
    #expect(throws: FramingError.messageTooLarge(limit: 16, pending: 4096)) {
        try framing.push(body("Content-Length: 4096\r\n\r\n"))
    }
}

/// Headers are capped on their own, generous limit — not on `maxBytes`, which governs
/// a body — so this takes far more than a small body limit to trip.
@Test func contentLengthRejectsHeadersThatNeverEnd() throws {
    var framing = ContentLengthFraming(maxBytes: 8)
    // Well under the header cap: still fine, however small the body limit is.
    #expect(try framing.push(body(String(repeating: "X-Pad: 1\r\n", count: 4))).isEmpty)
    // Past it: a peer that never sends a separator cannot buffer without bound.
    #expect(throws: (any Error).self) {
        try framing.push(body(String(repeating: "X-Pad: 1\r\n", count: 1024)))
    }
}

@Test func contentLengthIsUnlimitedByDefault() throws {
    var framing = ContentLengthFraming()
    let big = body(String(repeating: "y", count: 1 << 16))
    #expect(try framing.push(framing.frame(big)).count == 1)
}

/// A read can carry a good message and an oversized one together. The good one is
/// already delivered when the failure is reported — losing it because of what followed
/// it in the same buffer would be a bug in the framing, not in the peer.
@Test func lineFramingEmitsCompletedMessagesBeforeFailing() {
    var framing = LineFraming(maxBytes: 8)
    var emitted: [String] = []
    let chunk = framing.frame(body("{\"a\":1}")) + framing.frame(body(String(repeating: "x", count: 32)))

    #expect(throws: FramingError.messageTooLarge(limit: 8, pending: 32)) {
        try framing.push(chunk) { emitted.append(text($0) ?? "") }
    }
    #expect(emitted == ["{\"a\":1}"])
}

@Test func contentLengthEmitsCompletedMessagesBeforeFailing() {
    var framing = ContentLengthFraming(maxBytes: 8)
    var emitted: [String] = []
    let chunk = framing.frame(body("{\"a\":1}")) + framing.frame(body(String(repeating: "y", count: 64)))

    #expect(throws: FramingError.messageTooLarge(limit: 8, pending: 64)) {
        try framing.push(chunk) { emitted.append(text($0) ?? "") }
    }
    #expect(emitted == ["{\"a\":1}"])
}

/// A transport read can split anywhere, including inside a header that is longer than a
/// small body limit. The body limit must not be applied to the header.
@Test func contentLengthAcceptsAHeaderSplitUnderASmallLimit() throws {
    var framing = ContentLengthFraming(maxBytes: 16)
    let frame = framing.frame(body("{}"))
    let split = frame.count - 1

    #expect(try framing.push(frame.prefix(split)).isEmpty)
    let out = try framing.push(frame.suffix(from: split))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{}")
}
