//
//  JSONRPCMessage+Decoding.swift
//  JSONFoundation
//
//  Foundation-only, transport-independent decoding helpers. The protocol-version
//  batching gate (which needs a negotiated session) and any NIO `ByteBuffer`
//  overloads deliberately live in the consuming package, not here. Encoding is
//  the symmetric inverse in `JSONRPCMessage+Encoding.swift`.
//

import Foundation

extension JSONRPCMessage {
    /// Decode a single or batched JSON-RPC payload from `Data`.
    /// - Parameter data: Raw JSON data — either one message object or a top-level
    ///   array of messages (a JSON-RPC batch).
    /// - Returns: An array of `JSONRPCMessage` items (one element for a single
    ///   message).
    public static func decodeMessages(from data: Data) throws -> [JSONRPCMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([JSONRPCMessage].self, from: data)
        } catch {
            // A payload that is a batch but failed per-element must surface its
            // real error — falling through to the single-object decode would
            // replace it with a misleading type-mismatch about the array shape.
            if isBatchPayload(data) { throw error }
            return [try decoder.decode(JSONRPCMessage.self, from: data)]
        }
    }

    /// Whether `data` is a top-level JSON array (a JSON-RPC batch) rather than a
    /// single message.
    ///
    /// A single message is also decoded into a one-element array by
    /// ``decodeMessages(from:)``, so inspecting the raw payload is the only
    /// reliable way to recover the wire shape afterwards.
    public static func isBatchPayload(_ data: Data) -> Bool {
        var bytes = data[...]
        // JSONDecoder tolerates a UTF-8 BOM during encoding detection; skip it
        // so the shape sniff agrees with what the decoder would accept.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        for byte in bytes {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:   // space, tab, LF, CR — skip leading JSON whitespace
                continue
            case UInt8(ascii: "["):
                return true
            default:
                return false
            }
        }
        return false   // empty or whitespace-only: not a batch
    }
}
