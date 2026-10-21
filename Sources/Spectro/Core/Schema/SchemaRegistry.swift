import Foundation
@preconcurrency import PostgresNIO

// MARK: - FieldType
//
// A closed enum keeps FieldInfo's classification exhaustively switchable.
// The stored type itself is FieldInfo.valueType.

public enum FieldType: Sendable {
    case string
    case int
    case double
    case float
    case bool
    case uuid
    case date
    /// Any other `DatabaseValue`, such as `Decimal`, an array, an enum, or a JSONB value.
    case custom
}

// MARK: - FieldInfo

public struct FieldInfo: Sendable {
    public let name: String
    public let databaseName: String
    public let fieldType: FieldType
    public let isPrimaryKey: Bool
    public let isForeignKey: Bool
    public let isTimestamp: Bool
    public let isNullable: Bool
    public let isSoftDelete: Bool
    /// The stored Swift type, without `Optional` for nullable columns.
    public let valueType: any DatabaseValue.Type

    init(name: String, databaseName: String, valueType: any DatabaseValue.Type, isPrimaryKey: Bool = false,
         isForeignKey: Bool = false, isTimestamp: Bool = false, isNullable: Bool = false, isSoftDelete: Bool = false) {
        self.name = name
        self.databaseName = databaseName
        self.fieldType = valueType.fieldType
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
        self.isTimestamp = isTimestamp
        self.isNullable = isNullable
        self.isSoftDelete = isSoftDelete
        self.valueType = valueType
    }

    /// The Swift metatype for this field.
    ///
    /// Provided for backward compatibility with `SchemaMapper.extractValue(from:expectedType:)`.
    /// Prefer `valueType` for new code.
    public var type: Any.Type { valueType }

    /// Decode a column value as `valueType`, or `nil` for SQL NULL or an undecodable value.
    func decode(_ data: PostgresData) -> Any? {
        valueType.fromPostgresData(data)
    }
}

// MARK: - SchemaMetadata

public struct SchemaMetadata: Sendable {
    public let tableName: String
    public let fields: [FieldInfo]
    public let primaryKeyField: String?
    /// The snake_case database column name of the `@SoftDelete` field, or `nil` for hard-delete schemas.
    public let softDeleteField: String?

    public init(tableName: String, fields: [FieldInfo]) {
        self.tableName = tableName
        self.fields = fields
        self.primaryKeyField = fields.first(where: { $0.isPrimaryKey })?.name
        self.softDeleteField = fields.first(where: { $0.isSoftDelete })?.databaseName
    }
}

// MARK: - SchemaRegistry

public actor SchemaRegistry {
    // Keyed by type identity: names repeat across modules and nesting types.
    private var registry: [ObjectIdentifier: SchemaMetadata] = [:]

    public static let shared = SchemaRegistry()

    private init() {}

    public func register<T: Schema>(_ type: T.Type) -> SchemaMetadata {
        let key = ObjectIdentifier(type)
        if let existing = registry[key] { return existing }
        let metadata = Self.extractMetadata(from: type)
        registry[key] = metadata
        return metadata
    }

    public func metadata<T: Schema>(for type: T.Type) -> SchemaMetadata? {
        registry[ObjectIdentifier(type)]
    }

    // Pure inspection is also used by synchronous Changeset.cast.
    static func extractMetadata<T: Schema>(from type: T.Type) -> SchemaMetadata {
        let instance = T()
        let mirror = Mirror(reflecting: instance)
        let fields = mirror.children.compactMap { child -> FieldInfo? in
            guard let label = child.label else { return nil }
            return extractFieldInfo(label: label, value: child.value)
        }
        return SchemaMetadata(tableName: T.tableName, fields: fields)
    }

    private static func extractFieldInfo(label: String, value: Any) -> FieldInfo? {
        let fieldName = label.hasPrefix("_") ? String(label.dropFirst()) : label
        let defaultDBName = fieldName.snakeCase()

        switch value {
        case let pk as any PrimaryKeyWrapperProtocol:
            return FieldInfo(name: fieldName, databaseName: defaultDBName, valueType: pk.primaryKeyValueType, isPrimaryKey: true)

        case let col as any DatabaseColumnWrapper:
            let stored = type(of: col).storedType
            let wrapped = (stored as? any OptionalDatabaseValue.Type)?.wrappedValueType
            return FieldInfo(name: fieldName, databaseName: col.columnName ?? defaultDBName,
                             valueType: wrapped ?? stored, isNullable: wrapped != nil)

        case is Timestamp:
            return FieldInfo(name: fieldName, databaseName: defaultDBName, valueType: Date.self, isTimestamp: true)

        case is SoftDelete:
            return FieldInfo(name: fieldName, databaseName: defaultDBName, valueType: Date.self, isNullable: true, isSoftDelete: true)

        case let col as any ForeignKeyWrapperProtocol:
            let wrapped = (col.foreignKeyValueType as? any OptionalDatabaseValue.Type)?.wrappedValueType
            return FieldInfo(name: fieldName, databaseName: col.foreignKeyColumnName ?? defaultDBName,
                             valueType: wrapped ?? col.foreignKeyValueType, isForeignKey: true, isNullable: wrapped != nil)

        default:
            return nil
        }
    }
}

// MARK: - Schema Extension

extension Schema {
    public static var metadata: SchemaMetadata {
        get async {
            await SchemaRegistry.shared.register(self)
        }
    }
}
