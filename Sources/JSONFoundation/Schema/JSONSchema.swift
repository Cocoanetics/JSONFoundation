//
//  JSONSchema.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 08.03.25.
//

import Foundation

/// A simplified representation of JSON Schema for use in the macros
public indirect enum JSONSchema: Sendable, Equatable, Hashable {
    /**
     A structured schema type
     */
    public struct Object: Sendable, Equatable, Hashable {
        /// The properties of the type
        public var properties: [String: JSONSchema]

        /// Which of the properties are mandatory
        public var required: [String]

        /// Title of the type
        public var title: String?

        /// Description of the type
        public var description: String?

        /// Whether additional properties are allowed (`nil` omits the key from the schema)
        public var additionalProperties: Bool?

        /// public initializer
        public init(
            properties: [String: JSONSchema],
            required: [String],
            title: String? = nil,
            description: String? = nil,
            additionalProperties: Bool? = nil
        ) {
            self.properties = properties
            self.required = required
            self.title = title
            self.description = description
            self.additionalProperties = additionalProperties
        }
    }

    /// A string schema
    case string(
        title: String? = nil,
        description: String? = nil,
        format: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        defaultValue: JSONValue? = nil
    )

    /// A number schema
    case number(
        title: String? = nil,
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        defaultValue: JSONValue? = nil
    )

    /// A boolean schema
    case boolean(title: String? = nil, description: String? = nil, defaultValue: JSONValue? = nil)

    /// An array schema
    case array(
        items: JSONSchema,
        title: String? = nil,
        description: String? = nil,
        defaultValue: JSONValue? = nil
    )

    /// An object schema
    case object(Object, defaultValue: JSONValue? = nil)

    /// An enum schema with possible values
    case `enum`(
        values: [String],
        title: String? = nil,
        description: String? = nil,
        enumNames: [String]? = nil,
        defaultValue: JSONValue? = nil
    )

    /// A schema that matches any one of the provided schemas
    case oneOf(
        [JSONSchema],
        title: String? = nil,
        description: String? = nil
    )
}

// Extension to remove required fields from a schema
extension JSONSchema {
    /// Returns a new schema with all required fields removed
    public var withoutRequired: JSONSchema {
        switch self {
        case .object(let object, let defaultValue):
            // For object schemas, create a new object with empty required array
            return .object(Object(properties: object.properties.mapValues { $0.withoutRequired },
                                  required: [],
                                  title: object.title,
                                  description: object.description,
                                  additionalProperties: object.additionalProperties),
                           defaultValue: defaultValue)

        case .array(let items, let title, let description, let defaultValue):
            // For array schemas, recursively apply to items
            return .array(
                items: items.withoutRequired,
                title: title,
                description: description,
                defaultValue: defaultValue
            )

        // For other schema types, return as is since they don't have required fields
        case .string, .number, .boolean, .enum:
            return self

        case .oneOf(let schemas, let title, let description):
            return .oneOf(schemas.map(\.withoutRequired), title: title, description: description)
        }
    }
}

// Extension to compare schemas by shape rather than by documentation
extension JSONSchema {
    /// Returns a copy with every `description` removed, at every level.
    ///
    /// Two schemas that describe the same shape but document it differently
    /// compare as equal after this; titles, defaults, formats and bounds are
    /// all kept. This is what code generators want when deciding whether two
    /// occurrences of a titled schema are one type.
    public var withoutDescriptions: JSONSchema {
        switch self {
        case .string(let title, _, let format, let minLength, let maxLength, let defaultValue):
            return .string(
                title: title,
                description: nil,
                format: format,
                minLength: minLength,
                maxLength: maxLength,
                defaultValue: defaultValue
            )
        case .number(let title, _, let minimum, let maximum, let defaultValue):
            return .number(
                title: title,
                description: nil,
                minimum: minimum,
                maximum: maximum,
                defaultValue: defaultValue
            )
        case .boolean(let title, _, let defaultValue):
            return .boolean(title: title, description: nil, defaultValue: defaultValue)
        case .array(let items, let title, _, let defaultValue):
            return .array(
                items: items.withoutDescriptions,
                title: title,
                description: nil,
                defaultValue: defaultValue
            )
        case .object(let object, let defaultValue):
            return .object(Object(properties: object.properties.mapValues { $0.withoutDescriptions },
                                  required: object.required,
                                  title: object.title,
                                  description: nil,
                                  additionalProperties: object.additionalProperties),
                           defaultValue: defaultValue)
        case .enum(let values, let title, _, let enumNames, let defaultValue):
            return .enum(
                values: values,
                title: title,
                description: nil,
                enumNames: enumNames,
                defaultValue: defaultValue
            )
        case .oneOf(let schemas, let title, _):
            return .oneOf(schemas.map(\.withoutDescriptions), title: title, description: nil)
        }
    }
}

// Extension to apply default values when available
extension JSONSchema {
    /// Returns a copy with `defaultValue` filled in, unless the schema already carries one.
    ///
    /// `oneOf` schemas have no default-value slot and are returned unchanged.
    public func applyingDefault(_ defaultValue: JSONValue?) -> JSONSchema {
        guard let defaultValue else { return self }
        switch self {
        case .string(let title, let description, let format, let minLength, let maxLength, let existingDefault):
            return .string(
                title: title,
                description: description,
                format: format,
                minLength: minLength,
                maxLength: maxLength,
                defaultValue: existingDefault ?? defaultValue
            )
        case .number(let title, let description, let minimum, let maximum, let existingDefault):
            return .number(
                title: title,
                description: description,
                minimum: minimum,
                maximum: maximum,
                defaultValue: existingDefault ?? defaultValue
            )
        case .boolean(let title, let description, let existingDefault):
            return .boolean(
                title: title,
                description: description,
                defaultValue: existingDefault ?? defaultValue
            )
        case .array(let items, let title, let description, let existingDefault):
            return .array(
                items: items,
                title: title,
                description: description,
                defaultValue: existingDefault ?? defaultValue
            )
        case .object(let object, let existingDefault):
            return .object(object, defaultValue: existingDefault ?? defaultValue)
        case .enum(let values, let title, let description, let enumNames, let existingDefault):
            return .enum(
                values: values,
                title: title,
                description: description,
                enumNames: enumNames,
                defaultValue: existingDefault ?? defaultValue
            )
        case .oneOf:
            return self
        }
    }
}

// Extension to add additionalProperties:false to all objects, for use with structured results
// swiftlint:disable identifier_name
extension JSONSchema {
    /// Returns a new schema with `additionalProperties: false` set on every object, recursively
    public var addingAdditionalPropertiesRestrictionToObjects: JSONSchema {
        switch self {
        case .object(let object, let defaultValue):
            let updatedProperties = object.properties.mapValues {
                $0.addingAdditionalPropertiesRestrictionToObjects
            }
            return .object(
                Object(
                    properties: updatedProperties,
                    required: object.required,
                    title: object.title,
                    description: object.description,
                    additionalProperties: false
                ),
                defaultValue: defaultValue
            )

        case .array(let items, let title, let description, let defaultValue):
            // For array schemas, recursively apply to items
            return .array(
                items: items.addingAdditionalPropertiesRestrictionToObjects,
                title: title,
                description: description,
                defaultValue: defaultValue
            )

        // For other schema types, return as is since they don't have required fields
        case .oneOf(let schemas, let title, let description):
            return .oneOf(
                schemas.map(\.addingAdditionalPropertiesRestrictionToObjects),
                title: title,
                description: description
            )

        default:
            return self
        }
    }
}
// swiftlint:enable identifier_name
