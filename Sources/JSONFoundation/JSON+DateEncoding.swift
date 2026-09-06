//
//  JSON+DateEncoding.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 07.04.25.
//

import Foundation

/// The ISO 8601 formatters behind the `iso8601WithTimeZone` encoding and
/// decoding strategies — one per thread and option set.
///
/// Building an `ISO8601DateFormatter` costs on the order of a millisecond, and
/// the strategies run once per `Date`; a document with a few thousand dates
/// used to spend seconds constructing formatters. Each thread keeps its own
/// instance instead: `ISO8601DateFormatter`'s thread safety is not guaranteed
/// on non-Apple Foundation, and a formatter is only ever used synchronously
/// by the thread that owns it, so nothing is shared. The instance is rebuilt
/// when `TimeZone.current` no longer matches the one it was built with, so a
/// host time-zone change still shows up in the next encoded offset.
enum ISO8601Formatters {
    static let defaultOptions: ISO8601DateFormatter.Options = [.withInternetDateTime, .withTimeZone]
    static let fractionalOptions: ISO8601DateFormatter.Options = [
        .withInternetDateTime, .withTimeZone, .withFractionalSeconds
    ]

    /// The calling thread's formatter for `formatOptions` in `timeZone`
    /// (the host's current zone unless a test injects one).
    static func formatter(
        formatOptions: ISO8601DateFormatter.Options = defaultOptions,
        timeZone: TimeZone = .current
    ) -> ISO8601DateFormatter {
        let key = "JSONFoundation.ISO8601DateFormatter.\(formatOptions.rawValue)"
        let threadLocal = Thread.current.threadDictionary
        if let cached = threadLocal[key] as? ISO8601DateFormatter, cached.timeZone == timeZone {
            return cached
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = formatOptions
        threadLocal[key] = formatter
        return formatter
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Encodes a `Date` as an ISO 8601 string with an explicit UTC offset,
    /// e.g. `2025-04-07T14:00:00+02:00`. Sub-second precision is not encoded.
    ///
    /// The offset is the host machine's *current* time zone, so the encoded
    /// string for the same `Date` varies by machine — including in the
    /// otherwise-deterministic ``JSONCoding/makeWireEncoder()`` output.
    public static let iso8601WithTimeZone = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        let string = ISO8601Formatters.formatter().string(from: date)
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// Decodes an ISO 8601 string carrying a time-zone offset — the
    /// counterpart of `JSONEncoder.DateEncodingStrategy.iso8601WithTimeZone`.
    /// Accepts whole-second and fractional-second timestamps; anything else
    /// throws `DecodingError.dataCorrupted`.
    public static let iso8601WithTimeZone = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = ISO8601Formatters.formatter().date(from: string) {
            return date
        }
        // Common producers include fractional seconds, which the default
        // options reject; retry with them before giving up.
        if let date = ISO8601Formatters.formatter(formatOptions: ISO8601Formatters.fractionalOptions).date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
    }
}
