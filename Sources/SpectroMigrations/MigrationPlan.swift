/// An ordered, immutable collection of operations produced by ``MigrationBuilder``.
///
/// Use a migration's `change` property to build a plan. Compilation produces SQL
/// without connecting to PostgreSQL; plans do not contain database execution closures.
public struct MigrationPlan: Sendable {
    internal let operations: [MigrationOperation]
    internal init(_ operations: [MigrationOperation]) { self.operations = operations }
}

internal enum MigrationOperation: Sendable {
    case createTable(CreateTable)
    case alterTable(AlterTable)
    case createIndex(CreateIndex)
    case dropIndex(DropIndex)
    case dropTable(DropTable)
    case renameTable(RenameTable)
    case createEnum(CreateEnum)
    case sql(SQL)
    case reversible(Reversible)
    case irreversible(Irreversible)
}
