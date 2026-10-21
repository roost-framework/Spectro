/// PostgreSQL column types supported by the declarative migration DSL.
///
/// Use `named` for other types, such as an enum made with ``CreateEnum`` or an
/// extension's `citext`. Length, precision, and scale are validated when compiling the plan.
public indirect enum MigrationColumnType: Sendable {
    case uuid, text, integer, bigint, boolean, timestamptz, jsonb
    case smallint, real, doublePrecision, date, timestamp, bytea, json
    case varchar(length: Int)
    case numeric(precision: Int, scale: Int)
    /// An array of the element type, such as `.array(.text)` for `TEXT[]`.
    case array(MigrationColumnType)
    /// A type by name, quoted as one identifier and optionally qualified by its schema.
    case named(String, schema: String? = nil)
}

/// A literal column default or an explicitly trusted PostgreSQL expression.
///
/// String, integer, floating-point, and boolean literals are escaped as values.
/// Only `.sql` inserts an expression; never supply user input to that case.
public enum MigrationDefault: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String), integer(Int64), floating(Double), boolean(Bool), sql(String)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .floating(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

/// An immutable column declaration with optional constraints and a default.
///
/// Obtain a value from ``TableDefinitionContext/column(_:_:)`` or
/// ``AlterTableContext/add(_:_:)``. Each modifier returns a new declaration.
/// Repeating a modifier is a planning error.
public struct ColumnDefinition: Sendable {
    internal let name: String
    internal let type: MigrationColumnType
    internal var primary = false
    internal var required = false
    internal var defaultValue: MigrationDefault?
    internal var reference: ColumnReference?
    internal var modifiers = Set<String>()
    internal var issues: [String] = []

    internal init(name: String, type: MigrationColumnType) { self.name = name; self.type = type }

    /// Makes this the table's primary key column.
    public func primaryKey() -> Self { setting("primaryKey") { $0.primary = true } }
    /// Rejects null values in the column.
    public func notNull() -> Self { setting("notNull") { $0.required = true } }
    /// Sets a literal default or a trusted SQL expression.
    public func `default`(_ value: MigrationDefault) -> Self { setting("default") { $0.defaultValue = value } }

    /// Adds a foreign-key constraint without creating an index.
    ///
    /// - Parameters:
    ///   - table: The referenced table name.
    ///   - schema: The referenced schema, when explicitly qualified.
    ///   - column: The referenced column; defaults to `id`.
    ///   - onDelete: The deletion action; defaults to `NO ACTION`.
    ///   - name: An explicit constraint name, or the owning table and column names
    ///     joined with `_fkey` by default.
    public func references(_ table: String, schema: String? = nil, column: String = "id",
                           onDelete: ReferenceAction = .noAction, name: String? = nil) -> Self {
        setting("references") { $0.reference = .init(table: table, schema: schema, column: column, action: onDelete, name: name) }
    }

    internal func setting(_ key: String, _ change: (inout Self) -> Void) -> Self {
        var copy = self
        if !copy.modifiers.insert(key).inserted { copy.issues.append("Column \(name): \(key) was specified more than once") }
        change(&copy)
        return copy
    }
}

/// The action PostgreSQL takes when a referenced row is deleted.
///
/// `setNull` requires a nullable column; `setDefault` requires a declared default.
public enum ReferenceAction: String, Sendable {
    case noAction = "NO ACTION"
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"
}

internal struct ColumnReference: Sendable {
    let table: String
    let schema: String?
    let column: String
    let action: ReferenceAction
    let name: String?
}
