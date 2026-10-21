internal enum TableAlteration: Sendable {
    case add(ColumnDefinition)
    case rename(String, String)
    case remove(ColumnDefinition)
    case alterType(String, to: MigrationColumnType, from: MigrationColumnType)
    case required(String, Bool)
    case setDefault(String, to: MigrationDefault?, from: MigrationDefault?)
    case addConstraint(String, TableConstraint)
    case dropConstraint(String)
}

internal enum TableConstraint: Sendable {
    case check(String)
    case unique([String])
    case foreignKey(String, ColumnReference)
}

/// Ordered column and constraint changes collected by ``AlterTableBuilder``.
public struct TableAlterations: Sendable {
    internal let changes: [TableAlteration]
    internal init(_ changes: [TableAlteration]) { self.changes = changes }
}

/// Combines column and constraint changes for ``AlterTable``.
@resultBuilder
public enum AlterTableBuilder {
    public static func buildExpression(_ column: ColumnDefinition) -> TableAlterations { TableAlterations([.add(column)]) }
    public static func buildExpression(_ column: RemovedColumn) -> TableAlterations { TableAlterations([.remove(column.column)]) }
    public static func buildExpression(_ changes: TableAlterations) -> TableAlterations { changes }
    public static func buildBlock(_ changes: TableAlterations...) -> TableAlterations { combine(changes) }
    public static func buildOptional(_ changes: TableAlterations?) -> TableAlterations { changes ?? TableAlterations([]) }
    public static func buildEither(first: TableAlterations) -> TableAlterations { first }
    public static func buildEither(second: TableAlterations) -> TableAlterations { second }
    public static func buildArray(_ changes: [TableAlterations]) -> TableAlterations { combine(changes) }
    private static func combine(_ changes: [TableAlterations]) -> TableAlterations { TableAlterations(changes.flatMap(\.changes)) }
}

/// A column that ``AlterTableContext/remove(_:_:)`` drops, described so that automatic
/// rollback can add it back. Rollback restores the column, not its data.
public struct RemovedColumn: Sendable {
    internal let column: ColumnDefinition

    /// The column rejected null values. Rollback then needs a ``default(_:)`` for existing rows.
    public func notNull() -> Self { .init(column: column.notNull()) }
    /// The column had this default.
    public func `default`(_ value: MigrationDefault) -> Self { .init(column: column.default(value)) }
    /// The column had this foreign-key constraint. See ``ColumnDefinition/references(_:schema:column:onDelete:name:)``.
    public func references(_ table: String, schema: String? = nil, column referenced: String = "id",
                           onDelete: ReferenceAction = .noAction, name: String? = nil) -> Self {
        .init(column: column.references(table, schema: schema, column: referenced, onDelete: onDelete, name: name))
    }
}

/// The operation factory supplied to an ``AlterTable`` closure.
public struct AlterTableContext: Sendable {
    internal init() {}
    /// Adds a column, accepting the same modifiers as a new table's columns.
    ///
    /// Automatic rollback drops the column and its data.
    public func add(_ name: String, _ type: MigrationColumnType) -> ColumnDefinition { .init(name: name, type: type) }
    /// Renames a column; automatic rollback restores its previous name.
    public func rename(_ name: String, to newName: String) -> TableAlterations { .init([.rename(name, newName)]) }
    /// Drops a column and its data. Describe it with the modifiers of ``RemovedColumn`` so
    /// that automatic rollback adds it back empty.
    public func remove(_ name: String, _ type: MigrationColumnType) -> RemovedColumn {
        .init(column: .init(name: name, type: type))
    }
    /// Changes a column's type; automatic rollback restores `oldType`. PostgreSQL must be
    /// able to convert the values without a `USING` expression; use ``SQL`` otherwise.
    public func alter(_ name: String, type: MigrationColumnType, from oldType: MigrationColumnType) -> TableAlterations {
        .init([.alterType(name, to: type, from: oldType)])
    }
    /// Rejects null values in a column; automatic rollback accepts them again.
    public func setNotNull(_ name: String) -> TableAlterations { .init([.required(name, true)]) }
    /// Accepts null values in a column; automatic rollback rejects them again.
    public func dropNotNull(_ name: String) -> TableAlterations { .init([.required(name, false)]) }
    /// Sets a column's default, or drops it for `nil`; automatic rollback restores `oldValue`.
    public func setDefault(_ name: String, _ value: MigrationDefault?, from oldValue: MigrationDefault?) -> TableAlterations {
        .init([.setDefault(name, to: value, from: oldValue)])
    }
    /// Adds a named check using a trusted PostgreSQL expression; automatic rollback drops it.
    public func check(_ name: String, sql: String) -> TableAlterations { .init([.addConstraint(name, .check(sql))]) }
    /// Adds a named unique constraint over the columns; automatic rollback drops it.
    public func unique(_ name: String, columns: [String]) -> TableAlterations { .init([.addConstraint(name, .unique(columns))]) }
    /// Adds a foreign-key constraint to an existing column, without an index; automatic
    /// rollback drops it. The name defaults to the table and column names joined with `_fkey`.
    public func foreignKey(_ column: String, references table: String, schema: String? = nil, column referenced: String = "id",
                           onDelete: ReferenceAction = .noAction, name: String? = nil) -> TableAlterations {
        let reference = ColumnReference(table: table, schema: schema, column: referenced, action: onDelete, name: name)
        return .init([.addConstraint(name ?? "", .foreignKey(column, reference))])
    }
    /// Drops a constraint. The compiler cannot recreate it, so use this inside an explicit
    /// ``Reversible`` or ``Irreversible`` branch.
    public func dropConstraint(_ name: String) -> TableAlterations { .init([.dropConstraint(name)]) }
}
