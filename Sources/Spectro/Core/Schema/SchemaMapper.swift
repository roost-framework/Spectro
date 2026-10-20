import Foundation
@preconcurrency import PostgresNIO

/// Generic schema mapper that converts between database rows and Swift types
public struct SchemaMapper {

    public static func mapRow<T: Schema>(
        _ row: PostgresRow,
        to schemaType: T.Type,
        metadata: SchemaMetadata
    ) throws -> T {
        var instance = T()
        let values = try T.decodeValues(of: row, fields: metadata.fields)
        try applyValues(values, to: &instance, using: metadata)
        return instance
    }

    /// Encode an instance's stored fields, keyed by database column.
    /// - Throws: The error of a value that cannot be encoded, rather than leaving its column out.
    public static func extractData<T: Schema>(
        from instance: T,
        metadata: SchemaMetadata,
        excludePrimaryKey: Bool = false
    ) throws -> [String: PostgresData] {
        var data: [String: PostgresData] = [:]
        let mirror = Mirror(reflecting: instance)

        for child in mirror.children {
            guard let label = child.label else { continue }
            let fieldName = label.hasPrefix("_") ? String(label.dropFirst()) : label
            guard let field = metadata.fields.first(where: { $0.name == fieldName }) else { continue }
            if excludePrimaryKey && field.name == metadata.primaryKeyField { continue }
            if field.isSoftDelete { continue }

            if let value = extractPropertyWrapperValue(child.value) {
                data[field.databaseName] = try convertToPostgresData(value)
            }
        }

        return data
    }

    // MARK: - Value Extraction

    public static func extractValue(from dbValue: PostgresData, expectedType: Any.Type) -> Any? {
        (expectedType as? any DatabaseValue.Type)?.fromPostgresData(dbValue)
    }

    private static func applyValues<T: Schema>(
        _ values: [String: Any],
        to instance: inout T,
        using metadata: SchemaMetadata
    ) throws {
        if var mutable = instance as? MutableSchema {
            mutable.apply(values: values)
            guard let result = mutable as? T else {
                throw SpectroError.invalidSchema(
                    reason: "MutableSchema.apply(values:) returned incompatible type for \(T.self)"
                )
            }
            instance = result
        } else {
            throw SpectroError.notImplemented(
                "Schema \(T.self) must implement SchemaBuilder or MutableSchema for row mapping"
            )
        }
    }

    private static func extractPropertyWrapperValue(_ wrapper: Any) -> Any? {
        let mirror = Mirror(reflecting: wrapper)
        for child in mirror.children {
            if child.label == "wrappedValue" { return child.value }
        }
        return wrapper
    }

    public static func convertToPostgresData(_ value: Any) throws -> PostgresData {
        // Handle nil optionals explicitly — send SQL NULL instead of throwing.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional && mirror.children.isEmpty {
            return PostgresData(type: .null, value: nil)
        }

        guard let value = value as? any DatabaseValue else {
            throw SpectroError.invalidParameter(
                name: "value",
                value: String(describing: value),
                reason: "Unsupported type for PostgreSQL parameter: \(type(of: value)); conform it to DatabaseValue"
            )
        }
        return try value.toPostgresData()
    }
}

// MARK: - MutableSchema

public protocol MutableSchema {
    mutating func apply(values: [String: Any])
}
