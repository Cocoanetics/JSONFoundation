//
//  Schema.swift
//  JSONFoundation
//
//  The `@Schema` macro declaration. Attach it to a struct to synthesize
//  `SchemaRepresentable` conformance — the macro generates `schemaMetadata`
//  (a `SchemaMetadata` describing each stored property, with descriptions taken
//  from `///` doc comments) and the `MCPClientReturn` typealias.
//

/// Synthesizes `SchemaRepresentable` conformance for a struct.
///
/// ```swift
/// /// A person's contact information
/// @Schema
/// struct ContactInfo {
///     /// The person's full name
///     let name: String
///
///     /// The person's email address
///     let email: String
///
///     /// The person's phone number (optional)
///     let phone: String?
/// }
/// ```
///
/// The macro extracts the struct's description and each property's description
/// from documentation comments, and maps the property types to a ``JSONSchema``
/// via ``SchemaMetadata``. Apply it only to `struct` declarations; nested
/// structs used as property types must also be `@Schema`.
@attached(member, names: named(schemaMetadata), named(MCPClientReturn))
@attached(extension, conformances: SchemaRepresentable)
public macro Schema() = #externalMacro(module: "JSONFoundationMacros", type: "SchemaMacro")
