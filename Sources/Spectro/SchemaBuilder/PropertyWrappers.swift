import Foundation
import PostgresKit

// MARK: - Relationship Load Assertion
//
// Like Ecto's %Ecto.Association.NotLoaded{}, accessing a relationship that
// hasn't been preloaded is almost always a bug. In debug builds, we assert
// to catch this early. In release, we fall back to [] / nil silently.

@inline(__always)
func assertRelationLoaded<T>(_ relation: SpectroLazyRelation<T>, kind: String, type: Any.Type) {
    assert(relation.isLoaded,
        "\(kind)<\(type)> accessed before loading. Use .preload(\\.$relation) in your query, or check $relation.isLoaded first.")
}

// MARK: - Column Name Override Protocol

/// Protocol for property wrappers that support column name overrides.
protocol ColumnNameOverridable {
    var columnName: String? { get }
}

// MARK: - Column Wrappers

/// A stored column of a `DatabaseValue` type, with an optional database name.
@propertyWrapper
public struct Column<T: DatabaseValue>: Sendable, ColumnNameOverridable {
    public var wrappedValue: T
    public let columnName: String?

    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
        self.columnName = nil
    }

    public init(wrappedValue: T, _ columnName: String) {
        self.wrappedValue = wrappedValue
        self.columnName = columnName
    }
}

/// A `@Column` whose type schema metadata can read and decode.
protocol DatabaseColumnWrapper {
    var columnName: String? { get }
    static var storedType: any DatabaseValue.Type { get }
}

extension Column: DatabaseColumnWrapper {
    static var storedType: any DatabaseValue.Type { T.self }
}

@propertyWrapper
public struct ID<T: PrimaryKeyType>: Sendable, PrimaryKeyWrapperProtocol {
    public var wrappedValue: T

    public init(wrappedValue: T = T.defaultValue) { self.wrappedValue = wrappedValue }

    // MARK: - PrimaryKeyWrapperProtocol
    public var primaryKeyPostgresData: PostgresData { wrappedValue.toPostgresData() }
    public var primaryKeyFieldType: FieldType { T.fieldType }
    public var primaryKeyHashable: AnyHashable { AnyHashable(wrappedValue) }
    public var primaryKeyValueType: any DatabaseValue.Type { T.self }
}

@propertyWrapper
public struct Timestamp: Sendable {
    public var wrappedValue: Date
    public init(wrappedValue: Date = Date()) { self.wrappedValue = wrappedValue }
}

/// Marks a nullable `Date?` column as the soft-delete sentinel.
///
/// Queries automatically filter `WHERE deleted_at IS NULL`. Calling
/// `repo.delete(T.self, id:)` sets the column to `NOW()` instead of issuing a
/// hard `DELETE`. Use `.withDeleted()` on a query to bypass the filter.
@propertyWrapper
public struct SoftDelete: Sendable {
    public var wrappedValue: Date?
    public init(wrappedValue: Date? = nil) { self.wrappedValue = wrappedValue }
}

@propertyWrapper
public struct ForeignKey<T: PrimaryKeyType>: Sendable, ForeignKeyWrapperProtocol, ColumnNameOverridable {
    public var wrappedValue: T
    public let columnName: String?

    public init(wrappedValue: T = T.defaultValue) {
        self.wrappedValue = wrappedValue
        self.columnName = nil
    }

    public init(wrappedValue: T = T.defaultValue, _ columnName: String) {
        self.wrappedValue = wrappedValue
        self.columnName = columnName
    }

    // MARK: - ForeignKeyWrapperProtocol
    public var foreignKeyPostgresData: PostgresData { wrappedValue.toPostgresData() }
    public var foreignKeyFieldType: FieldType { T.fieldType }
    public var foreignKeyHashable: AnyHashable { AnyHashable(wrappedValue) }
    public var foreignKeyColumnName: String? { columnName }
    public var foreignKeyValueType: any DatabaseValue.Type { T.self }
}

// MARK: - Relationship Wrappers
//
// lazyRelation is stored as `var` so PreloadQuery can inject loaded data
// by writing to the projected value key path (\.$posts, \.$user, etc.).
// The projectedValue setter is what makes WritableKeyPath work.

@propertyWrapper
public struct HasMany<T: Schema>: Sendable {
    private var lazyRelation: SpectroLazyRelation<[T]>
    public let foreignKey: String?

    /// The loaded array. Triggers a debug assertion if accessed before preloading,
    /// similar to Ecto's `%Ecto.Association.NotLoaded{}`. In release builds,
    /// returns `[]` as a safe fallback. Use `$relation.isLoaded` to check first.
    public var wrappedValue: [T] {
        get {
            assertRelationLoaded(lazyRelation, kind: "HasMany", type: T.self)
            return lazyRelation.value ?? []
        }
        set { lazyRelation = lazyRelation.withLoaded(newValue) }
    }

    /// Access lazy-loading state and inject preloaded data.
    ///
    /// Setting this projected value is how `PreloadQuery` injects batch-loaded
    /// results: `entity[keyPath: \.$posts] = SpectroLazyRelation(loaded: posts, ...)`
    public var projectedValue: SpectroLazyRelation<[T]> {
        get { lazyRelation }
        set { lazyRelation = newValue }
    }

    public init(wrappedValue: [T] = []) {
        self.foreignKey = nil
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .hasMany,
            foreignKey: nil
        ))
    }

    public init(wrappedValue: [T] = [], foreignKey: String) {
        self.foreignKey = foreignKey
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .hasMany,
            foreignKey: foreignKey
        ))
    }

    public init(relationshipInfo: RelationshipInfo) {
        self.foreignKey = relationshipInfo.foreignKey
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: relationshipInfo)
    }
}

@propertyWrapper
public struct HasOne<T: Schema>: Sendable {
    private var lazyRelation: SpectroLazyRelation<T?>
    public let foreignKey: String?

    /// The loaded value. Triggers a debug assertion if accessed before preloading.
    /// In release builds, returns `nil` as a safe fallback.
    public var wrappedValue: T? {
        get {
            assertRelationLoaded(lazyRelation, kind: "HasOne", type: T.self)
            return lazyRelation.value ?? nil
        }
        set { lazyRelation = lazyRelation.withLoaded(newValue) }
    }

    public var projectedValue: SpectroLazyRelation<T?> {
        get { lazyRelation }
        set { lazyRelation = newValue }
    }

    public init(wrappedValue: T? = nil) {
        self.foreignKey = nil
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .hasOne,
            foreignKey: nil
        ))
    }

    public init(wrappedValue: T? = nil, foreignKey: String) {
        self.foreignKey = foreignKey
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .hasOne,
            foreignKey: foreignKey
        ))
    }

    public init(relationshipInfo: RelationshipInfo) {
        self.foreignKey = relationshipInfo.foreignKey
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: relationshipInfo)
    }
}

@propertyWrapper
public struct BelongsTo<T: Schema>: Sendable {
    private var lazyRelation: SpectroLazyRelation<T?>
    public let foreignKey: String?

    /// The loaded value. Triggers a debug assertion if accessed before preloading.
    /// In release builds, returns `nil` as a safe fallback.
    public var wrappedValue: T? {
        get {
            assertRelationLoaded(lazyRelation, kind: "BelongsTo", type: T.self)
            return lazyRelation.value ?? nil
        }
        set { lazyRelation = lazyRelation.withLoaded(newValue) }
    }

    public var projectedValue: SpectroLazyRelation<T?> {
        get { lazyRelation }
        set { lazyRelation = newValue }
    }

    public init(wrappedValue: T? = nil) {
        self.foreignKey = nil
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .belongsTo,
            foreignKey: nil
        ))
    }

    public init(wrappedValue: T? = nil, foreignKey: String) {
        self.foreignKey = foreignKey
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .belongsTo,
            foreignKey: foreignKey
        ))
    }

    public init(relationshipInfo: RelationshipInfo) {
        self.foreignKey = relationshipInfo.foreignKey
        self.lazyRelation = SpectroLazyRelation<T?>(relationshipInfo: relationshipInfo)
    }
}

@propertyWrapper
public struct ManyToMany<T: Schema>: Sendable {
    private var lazyRelation: SpectroLazyRelation<[T]>

    /// The loaded array. Triggers a debug assertion if accessed before preloading.
    /// In release builds, returns `[]` as a safe fallback.
    public var wrappedValue: [T] {
        get {
            assertRelationLoaded(lazyRelation, kind: "ManyToMany", type: T.self)
            return lazyRelation.value ?? []
        }
        set { lazyRelation = lazyRelation.withLoaded(newValue) }
    }

    /// Access lazy-loading state and inject preloaded data.
    public var projectedValue: SpectroLazyRelation<[T]> {
        get { lazyRelation }
        set { lazyRelation = newValue }
    }

    /// Create a many-to-many relationship.
    ///
    /// - Parameters:
    ///   - junctionTable: The name of the junction/pivot table (e.g. "user_tags").
    ///   - parentFK: The column in the junction table that references the parent's PK.
    ///               If nil, derived by convention from the parent type at preload time.
    ///   - relatedFK: The column in the junction table that references the related type's PK.
    ///                If nil, derived by convention from the related type at preload time.
    public init(junctionTable: String, parentFK: String? = nil, relatedFK: String? = nil) {
        let relatedTypeName = String(describing: T.self)
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: relatedTypeName,
            kind: .manyToMany,
            foreignKey: nil,
            junctionTable: junctionTable,
            parentForeignKey: parentFK ?? "",
            relatedForeignKey: relatedFK ?? ""
        ))
    }

    public init(wrappedValue: [T] = []) {
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: RelationshipInfo(
            name: "",
            relatedTypeName: String(describing: T.self),
            kind: .manyToMany,
            foreignKey: nil
        ))
    }

    public init(relationshipInfo: RelationshipInfo) {
        self.lazyRelation = SpectroLazyRelation<[T]>(relationshipInfo: relationshipInfo)
    }
}
