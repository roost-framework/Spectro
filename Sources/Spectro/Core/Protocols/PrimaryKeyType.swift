import Foundation
import PostgresKit

/// Types a `@ForeignKey` can hold: a `PrimaryKeyType`, or an `Optional` of one for a
/// nullable foreign key.
public protocol ForeignKeyValue: DatabaseValue, Hashable {
    /// The value of a foreign key that was not set.
    static var foreignKeyDefault: Self { get }
}

extension Optional: ForeignKeyValue where Wrapped: PrimaryKeyType {
    public static var foreignKeyDefault: Wrapped? { nil }
}

/// Types that can serve as primary keys in Spectro schemas.
///
/// Conform to this protocol to use a type as an `@ID` or `@ForeignKey` value.
/// Built-in conformances: `UUID`, `Int`, `String`.
public protocol PrimaryKeyType: ForeignKeyValue, Codable {
    /// Converts this value to `PostgresData` for query parameters.
    func toPostgresData() -> PostgresData

    /// The default value for uninitialized primary keys.
    static var defaultValue: Self { get }

    /// The corresponding `FieldType` for schema metadata.
    static var fieldType: FieldType { get }
}

extension PrimaryKeyType {
    public static var foreignKeyDefault: Self { defaultValue }
}

// MARK: - Built-in Conformances

extension UUID: PrimaryKeyType {
    public static var defaultValue: UUID { UUID() }
}

extension Int: PrimaryKeyType {
    public static var defaultValue: Int { 0 }
}

extension String: PrimaryKeyType {
    public static var defaultValue: String { "" }
}

// MARK: - Marker Protocols for Reflection

/// Non-generic marker protocol for runtime type checking of `ID<T>` via Mirror.
public protocol PrimaryKeyWrapperProtocol {
    /// The wrapped primary key value as `PostgresData`.
    var primaryKeyPostgresData: PostgresData { get }

    /// The `FieldType` of this primary key.
    var primaryKeyFieldType: FieldType { get }

    /// The wrapped value as `AnyHashable` for dictionary keying.
    var primaryKeyHashable: AnyHashable { get }

    /// The primary key's Swift type.
    var primaryKeyValueType: any DatabaseValue.Type { get }
}

extension PrimaryKeyWrapperProtocol {
    public var primaryKeyValueType: any DatabaseValue.Type { primaryKeyFieldType.builtInValueType }
}

/// Non-generic marker protocol for runtime type checking of `ForeignKey<T>` via Mirror.
public protocol ForeignKeyWrapperProtocol {
    /// The wrapped foreign key value as `PostgresData`.
    var foreignKeyPostgresData: PostgresData { get }

    /// The `FieldType` of this foreign key.
    var foreignKeyFieldType: FieldType { get }

    /// The wrapped value as `AnyHashable` for dictionary keying.
    var foreignKeyHashable: AnyHashable { get }

    /// The column name override, if any.
    var foreignKeyColumnName: String? { get }

    /// The foreign key's Swift type.
    var foreignKeyValueType: any DatabaseValue.Type { get }
}

extension ForeignKeyWrapperProtocol {
    public var foreignKeyValueType: any DatabaseValue.Type { foreignKeyFieldType.builtInValueType }
}

extension FieldType {
    /// The built-in type of each classification, for wrappers that predate `DatabaseValue`.
    var builtInValueType: any DatabaseValue.Type {
        switch self {
        case .string, .custom: String.self
        case .int: Int.self
        case .double: Double.self
        case .float: Float.self
        case .bool: Bool.self
        case .uuid: UUID.self
        case .date: Date.self
        }
    }
}
