import Foundation
@testable import JSONFoundation
import Testing

@Suite("JSONSchema equality")
struct JSONSchemaEquatableTests {
    private static func ride(description: String? = nil) -> JSONSchema {
        .object(.init(
            properties: [
                "id": .string(description: description),
                "rider_id": .string(),
                "stops": .array(items: .object(.init(properties: ["lat": .number()], required: ["lat"])))
            ],
            required: ["id"],
            title: "Ride"
        ))
    }

    @Test func identicalSchemasAreEqualAndHashAlike() {
        #expect(Self.ride() == Self.ride())
        #expect(Self.ride().hashValue == Self.ride().hashValue)
        #expect(Set([Self.ride(), Self.ride()]).count == 1)
    }

    @Test func aDifferentDescriptionIsADifferentValue() {
        #expect(Self.ride(description: "the id") != Self.ride(description: "an identifier"))
        #expect(Self.ride(description: "the id") != Self.ride())
    }

    @Test func withoutDescriptionsMakesThemEqual() {
        let documented = Self.ride(description: "the id")
        let rephrased = Self.ride(description: "an identifier")
        #expect(documented.withoutDescriptions == rephrased.withoutDescriptions)
        #expect(documented.withoutDescriptions == Self.ride())
    }

    @Test func aDifferentShapeStaysDifferent() {
        guard case .object(var object, _) = Self.ride() else {
            Issue.record("expected an object schema")
            return
        }
        object.properties["state"] = .string()
        #expect(JSONSchema.object(object) != Self.ride())
        #expect(JSONSchema.object(object).withoutDescriptions != Self.ride().withoutDescriptions)
    }

    @Test func requiredIsASetSoItsOrderIsNotShape() {
        guard case .object(let object, _) = Self.ride() else {
            Issue.record("expected an object schema")
            return
        }
        var oneWay = object
        oneWay.required = ["rider_id", "id"]
        var theOther = object
        theOther.required = ["id", "rider_id"]
        #expect(JSONSchema.object(oneWay) == JSONSchema.object(theOther))
        #expect(JSONSchema.object(oneWay).hashValue == JSONSchema.object(theOther).hashValue)
    }

    @Test func requiredEncodesSortedAndDecodesAsASet() throws {
        let schema: JSONSchema = .object(.init(
            properties: ["b": .string(), "a": .string(), "c": .string()], required: ["c", "a", "b"]
        ))
        let encoded = try JSONEncoder().encode(schema)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains(#""required":["a","b","c"]"#))
        let wire = #"{"type":"object","properties":{},"required":["b","a","a"]}"#
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: Data(wire.utf8))
        guard case .object(let object, _) = decoded else {
            Issue.record("expected an object schema")
            return
        }
        #expect(object.required == ["a", "b"])
    }

    @Test func requiredAndTitleTakePartInEquality() {
        guard case .object(let object, _) = Self.ride() else {
            Issue.record("expected an object schema")
            return
        }
        var untitled = object
        untitled.title = nil
        var laxer = object
        laxer.required = []
        #expect(JSONSchema.object(untitled) != Self.ride())
        #expect(JSONSchema.object(laxer) != Self.ride())
    }
}
