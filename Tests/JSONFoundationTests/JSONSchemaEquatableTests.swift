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

    @Test func requiredOrderIsNotShape() {
        guard case .object(let object, _) = Self.ride() else {
            Issue.record("expected an object schema")
            return
        }
        var reordered = object
        reordered.required = ["rider_id", "id"]
        var reference = object
        reference.required = ["id", "rider_id"]
        // Exact equality sees the order; the normalised comparison does not.
        #expect(JSONSchema.object(reordered) != JSONSchema.object(reference))
        #expect(JSONSchema.object(reordered).withSortedRequired == JSONSchema.object(reference).withSortedRequired)
    }

    @Test func withSortedRequiredReachesNestedObjects() {
        let nested: JSONSchema = .array(items: .object(.init(
            properties: ["b": .string(), "a": .string()], required: ["b", "a"]
        )))
        let expected: JSONSchema = .array(items: .object(.init(
            properties: ["b": .string(), "a": .string()], required: ["a", "b"]
        )))
        #expect(nested.withSortedRequired == expected)
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
