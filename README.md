# JSONFoundation

A small, dependency-free Swift package for working with JSON. A single module —
`JSONFoundation` — covering three layers that compose:

- **`JSONValue`** — a `Codable`/`Sendable` representation of an arbitrary JSON value
- **`JSONSchema`** — a model of JSON Schema, for *describing* data (e.g. tool/function parameter schemas)
- **JSON-RPC 2.0** — `Codable` request / response / notification / error envelope types

Pure Foundation, zero third-party dependencies — it builds on every Swift
platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android). Extracted from
[SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) and shared across SwiftMCP,
SwiftACP and SwiftAgents.

```swift
import JSONFoundation
```

## JSONValue

`JSONValue` is an `enum` over the JSON types — `null`, `bool`, `integer`,
`unsignedInteger`, `double`, `string`, `array`, `object` — that is `Codable`,
`Sendable`, `Hashable`, and ergonomic to build and inspect:

```swift
// ExpressibleBy* literals make construction terse:
let payload: JSONValue = [
    "name": "acp",
    "tags": ["a", "b"],
    "count": 3,
]

// Subscripts + typed accessors to read back out:
payload["name"]?.stringValue      // "acp"
payload["tags"]?[0]?.stringValue  // "a"

let data = try JSONEncoder().encode(payload)
let back = try JSONDecoder().decode(JSONValue.self, from: data)

// Bridge from / wrap other values:
let a = JSONValue(jsonObject: anyFromJSONSerialization) // Foundation `Any` -> JSONValue
let b = try JSONValue(encoding: someEncodable)          // throwing
let c = JSONValue(someEncodable)                        // best-effort, non-throwing
```

Typed accessors (`stringValue`, `intValue`, `doubleValue`, `boolValue`,
`arrayValue`, `dictionaryValue`) and the `JSONDictionary` / `JSONArray`
typealiases round it out.

## JSONSchema

`JSONSchema` is an `indirect enum` describing a JSON shape — `string`,
`number`, `boolean`, `array`, `object`, `enum`, `oneOf` — that round-trips to
and from standard JSON Schema. Use it wherever you need to *describe* data
rather than carry it, such as tool/function parameter schemas for LLMs or MCP:

```swift
let schema: JSONSchema = .object(.init(
    properties: [
        "city": .string(description: "City name"),
        "units": .enum(values: ["metric", "imperial"]),
    ],
    required: ["city"]
))
```

`SchemaRepresentable`, `SchemaMetadata`, `SchemaPropertyInfo` and
`JSONSchemaTypeConvertible` derive schemas from Swift types.

## JSON-RPC 2.0

Foundation-only envelope types for JSON-RPC 2.0 — the wire model only, no
transport (bring your own):

```swift
let request = JSONRPCMessage.request(id: .integer(1), method: "ping", params: nil)

// Errors are throwable and carry the standard codes:
throw JSONRPCError.methodNotFound("frobnicate")   // -32601

// Decode a single message or a batch from raw bytes:
let messages = try JSONRPCMessage.decodeMessages(from: data)
```

- `JSONRPCID` — `.integer` / `.string`
- `JSONRPCMessage` — `request` / `notification` / `response` / `errorResponse`
- `JSONRPCError` — `Error` + `LocalizedError`, with `.parseError` / `.invalidRequest` / `.methodNotFound` / `.invalidParams` / `.internalError` factories

## Installation

```swift
.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "1.2.0")
```

```swift
.product(name: "JSONFoundation", package: "JSONFoundation")
```

## License

BSD 2-Clause — see [LICENSE](LICENSE).
