import Foundation
import Testing
@testable import JSONFoundation

@Suite("JSONRPCMessage codec edge cases")
struct JSONRPCMessageCodecTests {
    /// Regression: a response with a nil result used to omit the `result` key —
    /// spec-invalid, and rejected by this library's own decoder.
    @Test func nilResultResponseEncodesAsNullAndRoundTrips() throws {
        let message = JSONRPCMessage.response(id: 7)
        let data = try message.encoded()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"result\":null"))

        let decoded = try JSONRPCMessage.decodeMessages(from: data)
        #expect(decoded == [.response(id: 7, result: .null)])
    }

    /// A UTF-8 BOM is tolerated by JSONDecoder, so the shape sniff (and thus
    /// the batch-error rethrow path) must tolerate it too.
    @Test func bomPrefixedBatchIsRecognizedAndDecodes() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"[{"jsonrpc":"2.0","id":1,"result":"ok"}]"#.utf8))
        #expect(JSONRPCMessage.isBatchPayload(data))
        let decoded = try JSONRPCMessage.decodeMessages(from: data)
        #expect(decoded == [.response(id: 1, result: .string("ok"))])
    }

    /// Regression: a batch with a malformed element used to fall through to the
    /// single-object decode, replacing the real per-element error with a
    /// misleading type mismatch about the array shape.
    @Test func malformedBatchElementSurfacesItsOwnError() {
        let data = Data(#"[{"jsonrpc":"2.0","id":1,"result":"ok"},{"bogus":true}]"#.utf8)
        do {
            _ = try JSONRPCMessage.decodeMessages(from: data)
            Issue.record("expected decodeMessages to throw")
        } catch let error as DecodingError {
            let path: [CodingKey]
            switch error {
            case .keyNotFound(_, let context), .dataCorrupted(let context),
                 .typeMismatch(_, let context), .valueNotFound(_, let context):
                path = context.codingPath
            @unknown default:
                path = []
            }
            // The failing element's index is preserved in the coding path.
            #expect(path.first?.intValue == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
