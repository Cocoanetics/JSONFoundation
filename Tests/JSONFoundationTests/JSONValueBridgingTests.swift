import Foundation
@testable import JSONFoundation
import Testing

/// Covers `JSONValue`'s Foundation-bridging paths — `init(jsonObject:)`,
/// `jsonObject`, the subscripts and typed accessors — plus the convenience
/// initializers and the ISO-8601 date strategies.
struct JSONValueBridgingTests {
    // MARK: - init(jsonObject:)

    @Test func bridgesJSONSerializationOutput() throws {
        let json = """
        {"flag": true, "off": false, "count": 2, "ratio": 2.5, \
        "name": "x", "missing": null, "items": [1.5, "y"], "nested": {"ok": true}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let value = JSONValue(jsonObject: object)
        #expect(value["flag"] == .bool(true))
        #expect(value["off"] == .bool(false))
        #expect(value["count"] == .integer(2))
        #expect(value["ratio"] == .double(2.5))
        #expect(value["name"] == .string("x"))
        #expect(value["missing"] == .null)
        #expect(value["items"] == .array([.double(1.5), .string("y")]))
        #expect(value["nested"] == .object(["ok": .bool(true)]))
    }

    /// Regression: on Darwin, `JSONSerialization` vends 0/1 as plain NSNumbers
    /// that SE-0170 bridging dynamic-casts to `Bool`, so JSON `0`/`1` used to
    /// classify as booleans (diverging from Linux). Numbers must stay numbers
    /// and only true booleans may become `.bool`, on every platform.
    @Test func bridgesZeroAndOneAsIntegersNotBooleans() throws {
        let object = try JSONSerialization.jsonObject(with: Data("[0, 1, true, false]".utf8))
        let value = JSONValue(jsonObject: object)
        #expect(value == .array([.integer(0), .integer(1), .bool(true), .bool(false)]))
        #expect(JSONValue(jsonObject: NSNumber(value: 0)) == .integer(0))
        #expect(JSONValue(jsonObject: NSNumber(value: 1)) == .integer(1))
    }

    @Test func bridgesNSNumberBooleans() {
        // NSNumber(value: Bool) is a CFBoolean on Darwin; it must classify as
        // .bool, not as the numerically equal 0/1 integer.
        #expect(JSONValue(jsonObject: NSNumber(value: true)) == .bool(true))
        #expect(JSONValue(jsonObject: NSNumber(value: false)) == .bool(false))
    }

    @Test func bridgesNSNumberIntegersAndDoubles() {
        #expect(JSONValue(jsonObject: NSNumber(value: Int64(-7))) == .integer(-7))
        #expect(JSONValue(jsonObject: NSNumber(value: Int64.max)) == .integer(Int(Int64.max)))
        #expect(JSONValue(jsonObject: NSNumber(value: UInt64.max)) == .unsignedInteger(UInt.max))
        #expect(JSONValue(jsonObject: NSNumber(value: 2.5)) == .double(2.5))
    }

    @Test func bridgesNilNSNullAndPassesJSONValueThrough() {
        #expect(JSONValue(jsonObject: nil) == .null)
        #expect(JSONValue(jsonObject: NSNull()) == .null)
        let existing = JSONValue.object(["k": .integer(1)])
        #expect(JSONValue(jsonObject: existing) == existing)
    }

    @Test func bridgesNestedSwiftContainers() {
        let value = JSONValue(jsonObject: [
            "names": ["a", "b"],
            "meta": ["depth": 2, "flag": true] as [String: Any]
        ] as [String: Any])
        #expect(value["names"] == .array([.string("a"), .string("b")]))
        #expect(value["meta"]?["depth"] == .integer(2))
        #expect(value["meta"]?["flag"] == .bool(true))
    }

    // MARK: - jsonObject

    @Test func jsonObjectRoundTripsThroughJSONSerialization() throws {
        let original: JSONValue = .object([
            "name": .string("x"),
            "count": .integer(3),
            "big": .unsignedInteger(UInt.max),
            "ratio": .double(0.5),
            "flags": .array([.bool(true), .null])
        ])
        let data = try JSONSerialization.data(withJSONObject: original.jsonObject)
        let decoded = JSONValue(jsonObject: try JSONSerialization.jsonObject(with: data))
        #expect(decoded == original)
    }

    // MARK: - Subscripts

    @Test func subscriptsReadObjectsAndArrays() {
        let value: JSONValue = ["items": [2, "two", true], "name": "demo"]
        #expect(value["name"] == .string("demo"))
        #expect(value["items"]?[1] == .string("two"))
        #expect(value["absent"] == nil)
        #expect(value["items"]?[3] == nil) // out of bounds
        #expect(value["items"]?[-1] == nil) // negative index
        #expect(JSONValue.string("x")["key"] == nil) // not an object
        #expect(JSONValue.string("x")[0] == nil) // not an array
    }

    // MARK: - Typed accessors

    @Test func typedAccessorsReturnPayloadsAndCrossConvert() {
        #expect(JSONValue.string("hi").stringValue == "hi")
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.integer(-3).intValue == -3)
        #expect(JSONValue.unsignedInteger(42).intValue == 42)
        #expect(JSONValue.unsignedInteger(UInt.max).intValue == nil)
        #expect(JSONValue.unsignedInteger(9).uintValue == 9)
        #expect(JSONValue.integer(7).uintValue == 7)
        #expect(JSONValue.integer(-1).uintValue == nil)
        #expect(JSONValue.double(2.5).doubleValue == 2.5)
        #expect(JSONValue.integer(4).doubleValue == 4.0)
        #expect(JSONValue.unsignedInteger(8).doubleValue == 8.0)
        #expect(JSONValue.array([.null]).arrayValue == [.null])
        #expect(JSONValue.object(["k": .null]).dictionaryValue == ["k": .null])
    }

    @Test func typedAccessorsReturnNilForOtherCases() {
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.string("1").boolValue == nil)
        #expect(JSONValue.double(1.5).intValue == nil)
        #expect(JSONValue.double(1.5).uintValue == nil)
        #expect(JSONValue.string("1.5").doubleValue == nil)
        #expect(JSONValue.object([:]).arrayValue == nil)
        #expect(JSONValue.array([]).dictionaryValue == nil)
    }

    // MARK: - Convenience initializers

    @Test func swiftContainerInitsBridgeElements() {
        let object = JSONValue(["name": "x", "count": 3] as [String: Any])
        #expect(object == .object(["name": .string("x"), "count": .integer(3)]))
        let array = JSONValue(["x", 3, 2.5] as [Any])
        #expect(array == .array([.string("x"), .integer(3), .double(2.5)]))
    }

    @Test func dictionaryBridgingInitConvertsValues() {
        let dict = [String: JSONValue](jsonObject: ["a": 3, "b": [true]] as [String: Any])
        #expect(dict["a"] == .integer(3))
        #expect(dict["b"] == .array([.bool(true)]))
    }

    @Test func encodableConvenienceInitPassesThroughExistingJSONValue() {
        let existing = JSONValue.array([.integer(1)])
        #expect(JSONValue(existing as any Encodable) == existing)
        #expect(JSONValue(nil as (any Encodable)?) == .null)
    }

    @Test func existentialEncodingBase64EncodesData() throws {
        let data = Data([1, 2, 3])
        let base64 = data.base64EncodedString()
        #expect(try JSONValue(encoding: data as any Encodable) == .string(base64))
        #expect(try JSONValue(encoding: [data] as any Encodable) == .array([.string(base64)]))
    }

    @Test func dictionaryEncodingInitThrowsForNonObjects() {
        #expect(throws: JSONValueError.self) {
            _ = try [String: JSONValue](encoding: 5)
        }
    }

    @Test func decodedRoundTripsCodableValues() throws {
        struct Payload: Codable, Equatable {
            var id: Int
            var label: String
        }
        let original = Payload(id: 7, label: "x")
        let bridged = try JSONValue(encoding: original)
        #expect(try bridged.decoded(Payload.self) == original)
        let dictionary = try [String: JSONValue](encoding: original)
        #expect(try dictionary.decoded(Payload.self) == original)
    }

    // MARK: - ISO-8601 date strategies

    private struct Stamped: Codable {
        var date: Date
    }

    private func makeDateCoders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithTimeZone
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithTimeZone
        return (encoder, decoder)
    }

    @Test func iso8601WithTimeZoneRoundTripsWholeSeconds() throws {
        // A whole-second date: the strategy does not encode sub-second
        // precision, so equality holds exactly.
        let original = Stamped(date: Date(timeIntervalSince1970: 1_700_000_000))
        let (encoder, decoder) = makeDateCoders()
        let decoded = try decoder.decode(Stamped.self, from: encoder.encode(original))
        #expect(decoded.date == original.date)
    }

    @Test func iso8601WithTimeZoneDecodesFractionalSeconds() throws {
        let (_, decoder) = makeDateCoders()
        let json = Data(#"{"date": "2025-04-07T12:00:00.500Z"}"#.utf8)
        let decoded = try decoder.decode(Stamped.self, from: json)
        let expected = Date(timeIntervalSince1970: 1_744_027_200.5)
        #expect(abs(decoded.date.timeIntervalSince(expected)) < 0.001)
    }

    @Test func iso8601WithTimeZoneRejectsMalformedDates() {
        let (_, decoder) = makeDateCoders()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Stamped.self, from: Data(#"{"date": "yesterday"}"#.utf8))
        }
    }

    private struct Stamps: Codable {
        var dates: [Date]
    }

    /// What the strategy must produce for `date`, built the expensive way.
    private func reference(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return formatter.string(from: date)
    }

    @Test func iso8601WithTimeZoneEncodesThousandsOfDatesLikeAFreshFormatter() throws {
        // The strategies reuse one formatter per thread; every date must still
        // come out exactly as a formatter built for that one call would encode
        // it, and decode back to the same instant.
        let dates = (0..<5_000).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 7_919) }
        let (encoder, decoder) = makeDateCoders()
        let started = Date()
        let data = try encoder.encode(Stamps(dates: dates))
        let decoded = try decoder.decode(Stamps.self, from: data)
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        print("iso8601WithTimeZone: \(dates.count) dates encoded+decoded in \(elapsed) ms")

        #expect(decoded.dates == dates)
        let strings = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])["dates"]
        #expect(strings?.count == dates.count)
        for (string, date) in zip(strings ?? [], dates) {
            #expect(string == reference(date))
        }
    }

    @Test func iso8601WithTimeZoneIsSafeAcrossThreads() throws {
        // Each thread owns its formatter; concurrent encoders and decoders
        // must never see each other's state.
        let dates = (0..<200).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 3_600) }
        let expected = dates.map(reference)
        let (encoder, decoder) = makeDateCoders()
        let failures = ManagedAtomicCounter()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            for _ in 0..<20 {
                guard let data = try? encoder.encode(Stamps(dates: dates)),
                      let strings = (try? JSONSerialization.jsonObject(with: data) as? [String: [String]])?["dates"],
                      strings == expected,
                      let decoded = try? decoder.decode(Stamps.self, from: data),
                      decoded.dates == dates else {
                    failures.increment()
                    continue
                }
            }
        }
        #expect(failures.value == 0)
    }

    @Test func iso8601FormatterIsReusedPerThreadAndRebuiltWhenTheTimeZoneMoves() throws {
        // Same zone, same thread: the same instance comes back. A different
        // zone (the host's zone changed) gets a fresh formatter that encodes
        // the new offset; the fractional-seconds variant is a separate instance.
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = ISO8601Formatters.formatter(timeZone: tokyo)
        let again = ISO8601Formatters.formatter(timeZone: tokyo)
        #expect(first === again)
        #expect(first.string(from: date) == "2023-11-15T07:13:20+09:00")

        let moved = ISO8601Formatters.formatter(timeZone: newYork)
        #expect(moved !== first)
        #expect(moved.string(from: date) == "2023-11-14T17:13:20-05:00")

        let fractional = ISO8601Formatters.formatter(
            formatOptions: ISO8601Formatters.fractionalOptions, timeZone: newYork)
        #expect(fractional !== moved)
        #expect(fractional.string(from: date) == "2023-11-14T17:13:20.000-05:00")
        #expect(ISO8601Formatters.formatter(timeZone: newYork) === moved)
    }
}

/// A lock-protected counter for the concurrency test (no swift-atomics dependency).
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
