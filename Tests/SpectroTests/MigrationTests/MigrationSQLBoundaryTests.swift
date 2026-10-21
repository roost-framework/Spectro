import Foundation
import Testing
import Spectro
import SpectroCommon
import SpectroMigrations

extension DatabaseIntegrationTests {
    @Suite("Migration SQL comment boundaries")
    struct MigrationSQLBoundaryTests {
        struct CommentedDefaults: Migration {
            static let id = "1900000020_commented_defaults"
            let parent: String
            let child: String
            var change: MigrationPlan {
                CreateTable(parent) { $0.column("id", .integer).primaryKey() }
                SQL(up: "INSERT INTO \(parent) VALUES (1)", down: "SELECT 1")
                CreateTable(child) {
                    $0.column("id", .integer).primaryKey()
                    $0.column("parent_id", .integer).default(.sql("1 -- default parent")).references(parent)
                }
                AlterTable(child) {
                    $0.add("backup_parent_id", .integer).default(.sql("1 -- backup parent")).references(parent)
                }
            }
        }

        struct CommentedPredicates: Migration {
            static let id = "1900000021_commented_predicates"
            let table: String
            let withCheck: Bool
            var change: MigrationPlan {
                CreateTable(table) {
                    $0.column("id", .integer).primaryKey()
                    $0.column("value", .integer).notNull()
                    if withCheck { $0.check("positive_value", sql: "value > 0 -- positive values only") }
                }
                CreateIndex("unique_\(table)", on: table, columns: ["value"])
                    .unique().whereSQL("value > 0 -- indexed values")
            }
        }

        struct CommentedStatements: Migration {
            static let id = "1900000022_commented_statements"
            let table: String
            let commentUp: Bool
            var upComment: String { commentUp ? " -- forward operation" : "" }
            var change: MigrationPlan {
                SQL(up: "CREATE TABLE \(table) (id INTEGER)\(upComment)",
                    down: "DROP TABLE \(table) -- remove table")
                SQL(up: "INSERT INTO \(table) VALUES (1)\(upComment)",
                    down: "DELETE FROM \(table) WHERE id=1 -- first row")
                Reversible {
                    SQL("INSERT INTO \(table) VALUES (2)\(upComment)")
                    SQL("INSERT INTO \(table) VALUES (3)\(upComment)")
                } down: {
                    SQL("DELETE FROM \(table) WHERE id=3 -- third row")
                    SQL("DELETE FROM \(table) WHERE id=2 -- second row")
                }
            }
        }

        private func withApplied<M: Migration>(_ migration: M, tables: [String],
            body: (DatabaseConnection) async throws -> Void) async throws {
            let db = try DatabaseConnection(configuration: .init(
                hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
                password: TestDatabase.password, database: TestDatabase.database,
                maxConnectionsPerEventLoop: 1, numberOfThreads: 1))
            do {
                let prepared = try MigrationCompiler.prepare(migration)
                let runner = MigrationRunner(connection: db, sources: [.prepared([prepared])])
                try await runner.runMigrations()
                try await body(db)
                try await runner.runRollback(steps: 1)
                for table in tables {
                    let absent = try await db.executeQuery(sql: "SELECT to_regclass('\(table)') IS NULL AS absent") {
                        $0.makeRandomAccess()[data: "absent"].bool
                    }
                    #expect(absent == [true])
                }
            } catch {
                try? await db.executeUpdate(sql: "DROP TABLE IF EXISTS \(tables.joined(separator: ", ")) CASCADE")
                try? await db.executeUpdate(sql: "DELETE FROM schema_migrations WHERE version='\(M.id)'")
                await db.shutdown()
                throw error
            }
            await db.shutdown()
        }

        @Test("Comments in defaults preserve foreign keys in create and alter operations")
        func defaultConstraints() async throws {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let parent = "comment_parent_\(suffix)", child = "comment_child_\(suffix)"
            try await withApplied(CommentedDefaults(parent: parent, child: child), tables: [child, parent]) { db in
                try await db.executeUpdate(sql: "INSERT INTO \(child) (id) VALUES (1)")
                let defaults = try await db.executeQuery(sql: "SELECT parent_id||':'||backup_parent_id AS value FROM \(child)") {
                    $0.makeRandomAccess()[data: "value"].string
                }
                #expect(defaults == ["1:1"])
                for (index, column) in ["parent_id", "backup_parent_id"].enumerated() {
                    await #expect(throws: SpectroError.self) {
                        try await db.executeUpdate(sql: "INSERT INTO \(child) (id, \(column)) VALUES (\(index + 2), 999)")
                    }
                }
            }
        }

        @Test("Comments cannot swallow check or partial index parentheses", arguments: [true, false])
        func predicates(withCheck: Bool) async throws {
            let table = "comment_predicate_" + UUID().uuidString.prefix(8).lowercased()
            try await withApplied(CommentedPredicates(table: table, withCheck: withCheck), tables: [table]) { db in
                try await db.executeUpdate(sql: "INSERT INTO \(table) VALUES (1, 1)")
                for values in withCheck ? ["(2, -1)", "(2, 1)"] : ["(2, 1)"] {
                    await #expect(throws: SpectroError.self) {
                        try await db.executeUpdate(sql: "INSERT INTO \(table) VALUES \(values)")
                    }
                }
            }
        }

        @Test("Raw SQL comments preserve statement boundaries in both directions and explicit branches", arguments: [true, false])
        func statements(commentUp: Bool) async throws {
            let table = "comment_statement_" + UUID().uuidString.prefix(8).lowercased()
            try await withApplied(CommentedStatements(table: table, commentUp: commentUp), tables: [table]) { db in
                let values = try await db.executeQuery(sql: "SELECT id::text AS value FROM \(table) ORDER BY id") {
                    $0.makeRandomAccess()[data: "value"].string
                }
                #expect(values == ["1", "2", "3"])
            }
        }
    }

@Suite("SQL migration transaction markers")
struct SQLMigrationMarkerTests {
    @Test("transaction:false after either marker, with any line ending, runs the file outside a transaction")
    func markers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spectro_markers_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            "1700000001_up_crlf": "-- migrate:up transaction:false\r\nCREATE INDEX CONCURRENTLY a ON t (x);\r\n-- migrate:down\r\nDROP INDEX a;\r\n",
            "1700000002_down": "-- migrate:up\nCREATE TABLE t (x INT);\n-- migrate:down transaction:false\nDROP INDEX CONCURRENTLY b;\n",
            "1700000003_plain": "-- migrate:up\nCREATE TABLE u (x INT);\n-- migrate:down\nDROP TABLE u;\n",
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent("\(name).sql"), atomically: true, encoding: .utf8)
        }
        let migrations = try MigrationCatalog.load(sources: [.sqlDirectory(directory)])
        #expect(migrations.map(\.runsInTransaction) == [false, false, true])
        #expect(migrations[0].upSQL == "CREATE INDEX CONCURRENTLY a ON t (x);")
        guard case .sql(let down) = migrations[1].rollback else { Issue.record("Expected a rollback"); return }
        #expect(down == "DROP INDEX CONCURRENTLY b;")
    }
}
}
