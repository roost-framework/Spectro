import Foundation
@preconcurrency import PostgresNIO
import SpectroCommon

/// Protocol for building schema instances from database rows.
///
/// Implement this to eliminate runtime reflection on the hot path.
/// Use the `@Schema` macro to generate the implementation automatically.
///
/// ```swift
/// @Schema
/// struct User: Schema { ... }
/// // @Schema generates:
/// // extension User: SchemaBuilder {
/// //     public static func build(from values: [String: Any]) -> User { ... }
/// // }
/// ```
public protocol SchemaBuilder: Schema {
    static func build(from values: [String: Any]) -> Self
}

/// Default no-op implementation. Concrete types should override via
/// `@Schema` macro or a manual `SchemaBuilder` conformance.
extension SchemaBuilder {
    public static func build(from values: [String: Any]) -> Self {
        Self()
    }
}

// MARK: - Row Mapping

extension Schema {
    /// Synchronous row mapping for contexts where async is unavailable.
    ///
    /// Reads field metadata with `Mirror` reflection on a default instance, without
    /// the `SchemaRegistry` cache, then decodes the row as `from(row:)` does.
    public static func fromSync(row: PostgresRow) throws -> Self {
        try buildInstance(from: decodeValues(of: row, fields: SchemaRegistry.extractMetadata(from: self).fields))
    }

    /// Decode each field's column, keyed by property name. NULL and undecodable values are omitted.
    /// - Parameter allowingMissingColumns: Leave fields without a column at their defaults,
    ///   as for a subset of columns chosen with `selectFields`, instead of throwing.
    internal static func decodeValues(of row: PostgresRow, fields: [FieldInfo], allowingMissingColumns: Bool = false) throws -> [String: Any] {
        let randomAccess = row.makeRandomAccess()
        var values: [String: Any] = [:]
        for field in fields {
            guard randomAccess.contains(field.databaseName) else {
                if allowingMissingColumns { continue }
                throw SpectroError.resultDecodingFailed(column: "\(tableName).\(field.databaseName)", expectedType: String(describing: field.valueType))
            }
            if let value = field.decode(randomAccess[data: field.databaseName]) {
                values[field.name] = value
            }
        }
        return values
    }

    internal static func buildInstance(from values: [String: Any]) throws -> Self {
        if let builderType = self as? any SchemaBuilder.Type {
            let built = builderType.build(from: values)
            guard let result = built as? Self else {
                throw SpectroError.invalidSchema(
                    reason: "SchemaBuilder.build(from:) returned incompatible type for \(Self.self)"
                )
            }
            return result
        }
        if var mutable = Self() as? MutableSchema {
            mutable.apply(values: values)
            guard let result = mutable as? Self else {
                throw SpectroError.invalidSchema(
                    reason: "MutableSchema.apply(values:) returned incompatible type for \(Self.self)"
                )
            }
            return result
        }
        throw SpectroError.invalidSchema(
            reason: "Schema \(Self.self) must conform to SchemaBuilder (use @Schema macro) or MutableSchema"
        )
    }

    /// Map a PostgreSQL row to a schema instance.
    ///
    /// 1. Registers the schema with `SchemaRegistry` to obtain field metadata.
    /// 2. Decodes each column as its field's `DatabaseValue` type.
    /// 3. Delegates construction to `SchemaBuilder.build(from:)` if available,
    ///    otherwise falls back to `MutableSchema.apply(values:)`.
    /// - Throws: `SpectroError.resultDecodingFailed` when the row lacks one of the schema's columns.
    public static func from(row: PostgresRow) async throws -> Self {
        try await from(row: row, allowingMissingColumns: false)
    }

    internal static func from(row: PostgresRow, allowingMissingColumns: Bool) async throws -> Self {
        let metadata = await SchemaRegistry.shared.register(self)
        return try buildInstance(from: decodeValues(of: row, fields: metadata.fields, allowingMissingColumns: allowingMissingColumns))
    }
}
