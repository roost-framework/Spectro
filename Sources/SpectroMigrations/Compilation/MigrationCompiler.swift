import Foundation
import Spectro
import SpectroCommon

/// Compiles a value plan without connecting to PostgreSQL.
public enum MigrationCompiler {
    /// Compiles one historical declaration into validated PostgreSQL and rollback.
    ///
    /// The body is evaluated once. Validation checks plan structure and statement
    /// boundaries; PostgreSQL validates SQL syntax and schema references at execution.
    /// - Throws: A planning error for an invalid ID, operation, or rollback definition.
    public static func prepare<M: Migration>(_ migration: M) throws -> PreparedMigration {
        try prepare(id: M.id, plan: migration.change, runsInTransaction: M.runsInTransaction)
    }

    internal static func prepare(id: String, plan: MigrationPlan, runsInTransaction: Bool = true) throws -> PreparedMigration {
        guard !plan.operations.isEmpty else { throw MigrationPlanningError(migrationID: id, reason: "Migration is empty") }
        if runsInTransaction && concurrent(plan) {
            throw MigrationPlanningError(migrationID: id, reason: "Concurrent index operations need a migration whose runsInTransaction is false")
        }
        var up: [String] = [], down: [String] = []
        var reasons: [String] = []
        for (position, operation) in plan.operations.enumerated() {
            do {
                let compiled = try automatic(operation)
                up.append(contentsOf: compiled.up)
                down.insert(contentsOf: compiled.down, at: 0)
                reasons.append(contentsOf: compiled.reasons)
            } catch let error as MigrationPlanningError {
                throw MigrationPlanningError(migrationID: id, operationIndex: position, reason: error.reason)
            }
        }
        let migration = PreparedMigration(version: id, name: String(id.split(separator: "_", maxSplits: 1).last ?? ""),
                                          upSQL: script(up), rollback: reasons.isEmpty ? .sql(script(down)) : .irreversible(reason: reasons.joined(separator: "; ")),
                                          runsInTransaction: runsInTransaction)
        _ = try MigrationCatalog.load(sources: [.prepared([migration])])
        return migration
    }

    private static func script(_ statements: [String]) -> String { statements.joined(separator: ";\n") + ";" }

    /// Whether the plan builds or drops an index concurrently, in either direction.
    private static func concurrent(_ plan: MigrationPlan) -> Bool {
        plan.operations.contains { operation in
            switch operation {
            case .createIndex(let index): index.isConcurrent
            case .dropIndex(let index): index.isConcurrent
            case .reversible(let branches): concurrent(branches.up) || concurrent(branches.down)
            case .irreversible(let operation): concurrent(operation.body)
            default: false
            }
        }
    }

    private struct Compiled {
        let up: [String]
        let down: [String]
        var reasons: [String] = []
    }

    private static func rawSQL(_ sql: String) throws -> String {
        _ = try MigrationCatalog.load(sources: [.prepared([.init(
            version: "1700000000_fragment", name: "fragment", upSQL: sql, rollback: .sql(sql))])])
        // Keep the generated statement separator outside any trailing line comment.
        return sql + "\n"
    }

    private static func validateReason(_ reason: String) throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MigrationPlanningError(reason: "An irreversible operation needs a reason")
        }
    }

    private static func automatic(_ operation: MigrationOperation) throws -> Compiled {
        switch operation {
        case .sql(let sql):
            guard let down = sql.down else { throw MigrationPlanningError(reason: "Unpaired SQL requires an explicit branch") }
            return try Compiled(up: [rawSQL(sql.up)], down: [rawSQL(down)])
        case .dropTable:
            throw MigrationPlanningError(reason: "DropTable requires an explicit branch")
        case .dropIndex:
            throw MigrationPlanningError(reason: "DropIndex requires an explicit branch")
        case .reversible(let branches):
            return try Compiled(up: forward(branches.up, isDown: false), down: forward(branches.down, isDown: true))
        case .irreversible(let operation):
            try validateReason(operation.reason)
            return try Compiled(up: forward(operation.body, isDown: false), down: [], reasons: [operation.reason])
        default:
            let result = try ordinary(operation)
            return Compiled(up: result.up, down: result.down)
        }
    }

    // Branch contents are explicit instructions: normal operations execute forward.
    // A nested Reversible selects the same direction, without inverting that branch again.
    private static func forward(_ plan: MigrationPlan, isDown: Bool) throws -> [String] {
        guard !plan.operations.isEmpty else { throw MigrationPlanningError(reason: "An explicit branch must not be empty") }
        return try plan.operations.flatMap { operation -> [String] in
            switch operation {
            case .sql(let sql):
                let up = try rawSQL(sql.up)
                if let down = sql.down { _ = try rawSQL(down) }
                return [up]
            case .dropTable(let table):
                return ["DROP TABLE \(try PostgresMigrationRenderer.qualified(table.name, schema: table.schema))"]
            case .dropIndex(let index):
                let concurrently = index.isConcurrent ? "CONCURRENTLY " : ""
                return ["DROP INDEX \(concurrently)\(try PostgresMigrationRenderer.qualified(index.name, schema: index.schema))"]
            case .reversible(let branches):
                return try forward(isDown ? branches.down : branches.up, isDown: isDown)
            case .irreversible(let operation):
                guard !isDown else { throw MigrationPlanningError(reason: "Irreversible cannot appear in an explicit down branch") }
                try validateReason(operation.reason)
                return try forward(operation.body, isDown: false)
            default: return try ordinary(operation, inBranch: true).up
            }
        }
    }

    /// Compiles an operation and its inverse. In an explicit branch, operations without an
    /// inverse, such as dropping a constraint, are allowed.
    private static func ordinary(_ operation: MigrationOperation, inBranch: Bool = false) throws -> (up: [String], down: [String]) {
        typealias SQL = PostgresMigrationRenderer
        switch operation {
        case .createTable(let table):
            let name = try SQL.qualified(table.name, schema: table.schema)
            let columns = table.elements.columns
            guard !columns.isEmpty else { throw MigrationPlanningError(reason: "A table must declare columns") }
            guard Set(columns.map(\.name)).count == columns.count else { throw MigrationPlanningError(reason: "Duplicate column name") }
            guard columns.filter(\.primary).count <= 1 else { throw MigrationPlanningError(reason: "Only one typed primary-key column is supported") }
            let constraintNames = columns.compactMap { SQL.referenceName($0, table: table.name) } + table.elements.checks.map(\.name)
            guard Set(constraintNames).count == constraintNames.count else { throw MigrationPlanningError(reason: "Duplicate constraint name") }
            let columnSQL = try columns.map { try SQL.column($0, table: table.name) }
            let checks = try table.elements.checks.map { "CONSTRAINT \(try SQL.identifier($0.name)) CHECK (\(try SQL.expression($0.sql)))" }
            let definitions = (columnSQL + checks).joined(separator: ",\n  ")
            return (["CREATE TABLE \(name) (\n  \(definitions)\n)"], ["DROP TABLE \(name)"])
        case .alterTable(let table):
            let name = try SQL.qualified(table.name, schema: table.schema)
            guard !table.alterations.changes.isEmpty else { throw MigrationPlanningError(reason: "An alteration must contain changes") }
            var up: [String] = [], down: [String] = []
            var added = Set<String>()
            for change in table.alterations.changes {
                switch change {
                case .add(let column):
                    guard added.insert(column.name).inserted else { throw MigrationPlanningError(reason: "Duplicate added column") }
                    up.append("ALTER TABLE \(name) ADD COLUMN \(try SQL.column(column, table: table.name))")
                    down.insert("ALTER TABLE \(name) DROP COLUMN \(try SQL.identifier(column.name))", at: 0)
                case .rename(let old, let new):
                    let old = try SQL.identifier(old), new = try SQL.identifier(new)
                    up.append("ALTER TABLE \(name) RENAME COLUMN \(old) TO \(new)")
                    down.insert("ALTER TABLE \(name) RENAME COLUMN \(new) TO \(old)", at: 0)
                case .remove(let column):
                    guard !column.required || column.defaultValue != nil else {
                        throw MigrationPlanningError(reason: "Removed column \(column.name): a NOT NULL column needs a default so that rollback can add it back to existing rows")
                    }
                    up.append("ALTER TABLE \(name) DROP COLUMN \(try SQL.identifier(column.name))")
                    down.insert("ALTER TABLE \(name) ADD COLUMN \(try SQL.column(column, table: table.name))", at: 0)
                case .alterType(let column, let type, let oldType):
                    let column = try SQL.identifier(column)
                    up.append("ALTER TABLE \(name) ALTER COLUMN \(column) TYPE \(try SQL.type(type))")
                    down.insert("ALTER TABLE \(name) ALTER COLUMN \(column) TYPE \(try SQL.type(oldType))", at: 0)
                case .required(let column, let required):
                    let column = try SQL.identifier(column)
                    let set = "ALTER TABLE \(name) ALTER COLUMN \(column) SET NOT NULL"
                    let drop = "ALTER TABLE \(name) ALTER COLUMN \(column) DROP NOT NULL"
                    up.append(required ? set : drop)
                    down.insert(required ? drop : set, at: 0)
                case .setDefault(let column, let value, let oldValue):
                    let column = try SQL.identifier(column)
                    func clause(_ value: MigrationDefault?) throws -> String {
                        try value.map { "SET DEFAULT \(try SQL.value($0))" } ?? "DROP DEFAULT"
                    }
                    up.append("ALTER TABLE \(name) ALTER COLUMN \(column) \(try clause(value))")
                    down.insert("ALTER TABLE \(name) ALTER COLUMN \(column) \(try clause(oldValue))", at: 0)
                case .addConstraint(let constraintName, let constraint):
                    let definition: String
                    var resolvedName = constraintName
                    switch constraint {
                    case .check(let sql):
                        definition = "CHECK (\(try SQL.expression(sql)))"
                    case .unique(let columns):
                        guard !columns.isEmpty, Set(columns).count == columns.count else {
                            throw MigrationPlanningError(reason: "A unique constraint needs distinct columns")
                        }
                        definition = "UNIQUE (\(try columns.map(SQL.identifier).joined(separator: ", ")))"
                    case .foreignKey(let column, let reference):
                        if resolvedName.isEmpty { resolvedName = "\(table.name)_\(column)_fkey" }
                        definition = "FOREIGN KEY (\(try SQL.identifier(column))) REFERENCES "
                            + "\(try SQL.qualified(reference.table, schema: reference.schema)) (\(try SQL.identifier(reference.column)))"
                            + " ON DELETE \(reference.action.rawValue)"
                    }
                    let constraint = try SQL.identifier(resolvedName)
                    up.append("ALTER TABLE \(name) ADD CONSTRAINT \(constraint) \(definition)")
                    down.insert("ALTER TABLE \(name) DROP CONSTRAINT \(constraint)", at: 0)
                case .dropConstraint(let constraint):
                    guard inBranch else { throw MigrationPlanningError(reason: "dropConstraint requires an explicit branch") }
                    up.append("ALTER TABLE \(name) DROP CONSTRAINT \(try SQL.identifier(constraint))")
                }
            }
            return (up, down)
        case .renameTable(let rename):
            let old = try SQL.qualified(rename.name, schema: rename.schema)
            let new = try SQL.qualified(rename.newName, schema: rename.schema)
            return (["ALTER TABLE \(old) RENAME TO \(try SQL.identifier(rename.newName))"],
                    ["ALTER TABLE \(new) RENAME TO \(try SQL.identifier(rename.name))"])
        case .createEnum(let type):
            guard !type.values.isEmpty, Set(type.values).count == type.values.count,
                  type.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else {
                throw MigrationPlanningError(reason: "An enum needs distinct labels of 1...63 UTF-8 bytes")
            }
            let name = try SQL.qualified(type.name, schema: type.schema)
            let labels = try type.values.map { try SQL.value(.string($0)) }.joined(separator: ", ")
            return (["CREATE TYPE \(name) AS ENUM (\(labels))"], ["DROP TYPE \(name)"])
        case .createIndex(let index):
            if let issue = index.issues.first { throw MigrationPlanningError(reason: issue) }
            guard !index.columns.isEmpty, Set(index.columns).count == index.columns.count else {
                throw MigrationPlanningError(reason: "An index needs distinct columns")
            }
            let name = try SQL.identifier(index.name)
            let table = try SQL.qualified(index.table, schema: index.schema)
            let columns = try index.columns.map(SQL.identifier).joined(separator: ", ")
            let unique = index.isUnique ? "UNIQUE " : ""
            let concurrently = index.isConcurrent ? "CONCURRENTLY " : ""
            let predicate = try index.predicate.map { " WHERE (\(try SQL.expression($0)))" } ?? ""
            return (["CREATE \(unique)INDEX \(concurrently)\(name) ON \(table) (\(columns))\(predicate)"],
                    ["DROP INDEX \(concurrently)\(try SQL.qualified(index.name, schema: index.schema))"])
        default: throw MigrationPlanningError(reason: "Expected an ordinary schema operation")
        }
    }
}
