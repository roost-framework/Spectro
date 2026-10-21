/// Creates a table with explicit columns, references, and checks.
///
/// No primary key is added implicitly. Automatic rollback drops the table.
public struct CreateTable: MigrationStep {
    internal let name: String
    internal let schema: String?
    internal let elements: TableElements

    /// Declares a table in the default or explicitly named schema.
    ///
    /// - Parameters:
    ///   - name: The table identifier, quoted as one name.
    ///   - schema: A separate schema identifier; a dot in `name` is not a separator.
    ///   - content: The columns and checks to capture in declaration order.
    public init(_ name: String, schema: String? = nil,
                @TableBuilder _ content: (TableDefinitionContext) -> TableElements) {
        self.name = name
        self.schema = schema
        self.elements = content(TableDefinitionContext())
    }

    public var migrationPlan: MigrationPlan { MigrationPlan([.createTable(self)]) }
}

/// Adds or renames columns on an existing table.
///
/// Automatic rollback inverts the operations in reverse declaration order.
public struct AlterTable: MigrationStep {
    internal let name: String
    internal let schema: String?
    internal let alterations: TableAlterations

    /// Declares column changes for the named table and optional schema.
    public init(_ name: String, schema: String? = nil,
                @AlterTableBuilder _ content: (AlterTableContext) -> TableAlterations) {
        self.name = name
        self.schema = schema
        self.alterations = content(AlterTableContext())
    }

    public var migrationPlan: MigrationPlan { MigrationPlan([.alterTable(self)]) }
}

/// Renames a table; automatic rollback restores its previous name.
public struct RenameTable: MigrationStep {
    internal let name: String
    internal let newName: String
    internal let schema: String?

    /// Declares the table, its new name, and the optional schema both share.
    public init(_ name: String, to newName: String, schema: String? = nil) {
        self.name = name
        self.newName = newName
        self.schema = schema
    }

    public var migrationPlan: MigrationPlan { MigrationPlan([.renameTable(self)]) }
}

/// Creates an enum type, for columns of type `.named(name)`; automatic rollback drops it.
///
/// Its labels are escaped as string literals. Swift enums with matching raw values store
/// and decode through it.
public struct CreateEnum: MigrationStep {
    internal let name: String
    internal let values: [String]
    internal let schema: String?

    /// Declares the type and its labels, in sort order.
    public init(_ name: String, values: [String], schema: String? = nil) {
        self.name = name
        self.values = values
        self.schema = schema
    }

    public var migrationPlan: MigrationPlan { MigrationPlan([.createEnum(self)]) }
}
