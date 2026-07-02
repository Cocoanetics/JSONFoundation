import Testing
import Foundation
@testable import JSONFoundation

/// A person's contact information
@Schema
struct ContactInfo: Codable, Sendable {
    /// The person's full name
    let name: String
    /// The person's email address
    let email: String
    /// The person's phone number (optional)
    let phone: String?
    /// The person's age
    let age: Int = 0
}

/// A recipient with wire keys renamed via a (non-private) CodingKeys enum
@Schema
struct Recipient: Codable, Sendable {
    /// Die Straße des Empfängers 🏠
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

@Suite("@Schema macro (moved into JSONFoundation)")
struct SchemaMacroTests {
    @Test func synthesizesSchemaRepresentableConformance() {
        // The macro adds `: SchemaRepresentable` — usable as the existential.
        let representable: any SchemaRepresentable.Type = ContactInfo.self
        #expect(representable.schemaMetadata.name == "ContactInfo")
    }

    @Test func capturesStructAndPropertyDocumentation() {
        let metadata = ContactInfo.schemaMetadata
        #expect(metadata.description == "A person's contact information")
        let byName = Dictionary(uniqueKeysWithValues: metadata.parameters.map { ($0.name, $0) })
        #expect(byName["name"]?.description == "The person's full name")
        #expect(byName["email"]?.description == "The person's email address")
    }

    @Test func marksRequiredVersusOptionalAndDefaulted() {
        let byName = Dictionary(uniqueKeysWithValues: ContactInfo.schemaMetadata.parameters.map { ($0.name, $0) })
        #expect(byName["name"]?.isRequired == true)    // non-optional, no default
        #expect(byName["phone"]?.isRequired == false)  // optional
        #expect(byName["age"]?.isRequired == false)    // has a default value
    }

    @Test func producesAJSONSchema() {
        // SchemaMetadata bridges to a JSONSchema (the model already in JSONFoundation).
        let schema = ContactInfo.schemaMetadata.schema
        let encoded = try? JSONEncoder().encode(schema)
        #expect(encoded != nil)
    }

    /// Regression: the macro used to honor CodingKeys only when the enum was
    /// declared `private`; an internal one was silently ignored, so schema and
    /// wire format disagreed.
    @Test func honorsNonPrivateCodingKeys() {
        let names = Recipient.schemaMetadata.parameters.map(\.name)
        #expect(names == ["full_name"])
    }

    /// Regression: doc comments used to be stripped to printable ASCII, mangling
    /// umlauts, accents, and emoji in the generated descriptions.
    @Test func preservesNonASCIIDocumentation() {
        let description = Recipient.schemaMetadata.parameters.first?.description
        #expect(description == "Die Straße des Empfängers 🏠")
    }
}
