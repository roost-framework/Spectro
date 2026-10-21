import Foundation
import Testing
import Spectro
import SpectroCommon
import SpectroMigrations

extension DatabaseIntegrationTests {
    @Suite("Swift migration PostgreSQL behavior")
    struct MigrationDSLIntegrationTests {
        struct Tables: Migration {
            static let id = "1900000000_dsl_constraints"
            let parent: String
            let child: String
            let stringMode: String
            var change: MigrationPlan {
                SQL(up: "SET LOCAL standard_conforming_strings = \(stringMode)", down: "SELECT 1")
                CreateTable(parent) { $0.column("id", .integer).primaryKey() }
                CreateTable(child) { table in
                    table.column("id", .integer).primaryKey()
                    table.column("parent_id", .integer).notNull().references(parent, onDelete: .restrict, name: "parent_fk")
                    table.column("title", .text).notNull().default("O'Reilly\\path; -- safe")
                    table.column("empty", .text).default("")
                    table.column("active", .boolean).notNull().default(false)
                    table.column("priority", .integer).notNull().default(0)
                    table.check("priority_check", sql: "priority >= 0")
                }
                CreateIndex("partial_\(child)", on: child, columns: ["title"]).unique().whereSQL("active")
            }
        }

        struct Alteration: Migration {
            static let id = "1900000001_dsl_alteration"
            let table: String
            var change: MigrationPlan {
                AlterTable(table) {
                    $0.rename("title", to: "heading")
                    $0.add("body", .text)
                }
            }
        }

        private func connection() throws -> DatabaseConnection {
            try DatabaseConnection(configuration: .init(
                hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
                password: TestDatabase.password, database: TestDatabase.database,
                maxConnectionsPerEventLoop: 1, numberOfThreads: 1))
        }

        @Test("Constraints, defaults and nested reversals execute with a single connection")
        func persistedBehavior() async throws {
            let db = try connection()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let parent = "dsl_parent_\(suffix)", child = "dsl_child_\(suffix)"
            do {
                for setting in ["on", "off"] {
                    let tables = try MigrationCompiler.prepare(Tables(parent: parent, child: child, stringMode: setting))
                    let alteration = try MigrationCompiler.prepare(Alteration(table: child))
                    let runner = MigrationRunner(connection: db, sources: [.prepared([tables])])
                    try await runner.runMigrations()
                    try await db.executeUpdate(sql: "INSERT INTO \(parent) VALUES (1)")
                    try await db.executeUpdate(sql: "INSERT INTO \(child) (id,parent_id) VALUES (1,1),(2,1)")
                    let values = try await db.executeQuery(sql: "SELECT title,empty FROM \(child) ORDER BY id") {
                        let row = $0.makeRandomAccess()
                        return [row[data: "title"].string, row[data: "empty"].string]
                    }
                    #expect(values == [["O'Reilly\\path; -- safe", ""], ["O'Reilly\\path; -- safe", ""]])
                    for sql in [
                        "INSERT INTO \(child) (id,parent_id) VALUES (3,999)",
                        "INSERT INTO \(child) (id,parent_id,priority) VALUES (3,1,-1)",
                        "DELETE FROM \(parent) WHERE id=1"
                    ] {
                        await #expect(throws: SpectroError.self) { try await db.executeUpdate(sql: sql) }
                    }
                    try await db.executeUpdate(sql: "INSERT INTO \(child) (id,parent_id,active) VALUES (3,1,true)")
                    await #expect(throws: SpectroError.self) {
                        try await db.executeUpdate(sql: "INSERT INTO \(child) (id,parent_id,active) VALUES (4,1,true)")
                    }
                    let all = MigrationRunner(connection: db, sources: [.prepared([tables, alteration])])
                    try await all.runMigrations()
                    try await all.runRollback(steps: 1)
                    let rows = try await db.executeQuery(sql: "SELECT title FROM \(child)") { $0.makeRandomAccess()[data: "title"].string }
                    #expect(rows.count == 3)
                    try await all.runMigrations()
                    try await all.runRollback(steps: 2)
                }
            } catch {
                try? await db.executeUpdate(sql: "DROP TABLE IF EXISTS \(child), \(parent) CASCADE")
                try? await db.executeUpdate(sql: "DELETE FROM schema_migrations WHERE version IN ('\(Tables.id)','\(Alteration.id)')")
                await db.shutdown()
                throw error
            }
            await db.shutdown()
        }

        struct Function: Migration {
            static let id = "1900000002_dsl_function"
            let name: String
            var change: MigrationPlan {
                SQL(up: "CREATE FUNCTION \(name)() RETURNS TEXT AS $$ BEGIN RETURN 'hello;world'; END; $$ LANGUAGE plpgsql",
                    down: "DROP FUNCTION \(name)()")
            }
        }

        @Test("Dollar-quoted SQL executes intact and concurrent indexes remain transactional")
        func rawSQL() async throws {
            let db = try connection()
            let name = "dsl_function_" + UUID().uuidString.prefix(8).lowercased()
            do {
                let function = try MigrationCompiler.prepare(Function(name: name))
                let runner = MigrationRunner(connection: db, sources: [.prepared([function])])
                try await runner.runMigrations()
                let values = try await db.executeQuery(sql: "SELECT \(name)() AS value") { $0.makeRandomAccess()[data: "value"].string }
                #expect(values == ["hello;world"])
                try await runner.runRollback(steps: 1)
                let concurrent = PreparedMigration(version: "1900000003_dsl_concurrent", name: "dsl_concurrent",
                    upSQL: "CREATE TABLE \(name) (id INT); CREATE INDEX CONCURRENTLY \(name)_idx ON \(name) (id)",
                    rollback: .sql("DROP TABLE \(name)"))
                let failing = MigrationRunner(connection: db, sources: [.prepared([concurrent])])
                await #expect(throws: SpectroError.self) { try await failing.runMigrations() }
                let recorded = try await failing.getMigrationStatus().contains { $0.version == concurrent.version }
                #expect(!recorded)
                let exists = try await db.executeQuery(sql: "SELECT to_regclass('\(name)') IS NOT NULL AS present") {
                    $0.makeRandomAccess()[data: "present"].bool
                }
                #expect(exists == [false])
            } catch {
                try? await db.executeUpdate(sql: "DROP FUNCTION IF EXISTS \(name)(); DROP TABLE IF EXISTS \(name)")
                try? await db.executeUpdate(sql: "DELETE FROM schema_migrations WHERE version IN ('\(Function.id)','1900000003_dsl_concurrent')")
                await db.shutdown()
                throw error
            }
            await db.shutdown()
        }

        struct Shape: Migration {
            static let id = "1900000010_dsl_shape"
            let suffix: String
            var change: MigrationPlan {
                CreateEnum("mood_\(suffix)", values: ["happy", "sad"])
                CreateTable("owners_\(suffix)") { $0.column("id", .integer).primaryKey() }
                CreateTable("entries_\(suffix)") { table in
                    table.column("id", .integer).primaryKey()
                    table.column("title", .text)
                    table.column("views", .integer).notNull().default(0)
                    table.column("legacy", .text)
                    table.column("owner_id", .integer)
                    table.column("mood", .named("mood_\(suffix)"))
                    table.column("tags", .array(.text))
                }
            }
        }

        struct Reshape: Migration {
            static let id = "1900000011_dsl_reshape"
            let suffix: String
            var change: MigrationPlan {
                AlterTable("entries_\(suffix)") { table in
                    table.remove("legacy", .text)
                    table.alter("views", type: .bigint, from: .integer)
                    table.setNotNull("title")
                    table.setDefault("mood", .sql("'happy'"), from: nil)
                    table.check("entries_\(suffix)_views", sql: "views >= 0")
                    table.unique("entries_\(suffix)_title", columns: ["title"])
                    table.foreignKey("owner_id", references: "owners_\(suffix)")
                }
                RenameTable("entries_\(suffix)", to: "posts_\(suffix)")
            }
        }

        struct ConcurrentIndex: Migration {
            static let id = "1900000012_dsl_concurrent_index"
            static let runsInTransaction = false
            let suffix: String
            var change: MigrationPlan {
                CreateIndex("posts_\(suffix)_views", on: "posts_\(suffix)", columns: ["views"]).concurrently()
            }
        }

        @Test("Alterations, enum types, renames, and concurrent indexes apply and roll back")
        func reshape() async throws {
            let db = try connection()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spectro_sql_\(suffix)")
            let ids = [Shape.id, Reshape.id, ConcurrentIndex.id, "1900000013_sql_concurrent"]
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try """
                    -- migrate:up transaction:false
                    CREATE INDEX CONCURRENTLY "posts_\(suffix)_title" ON "posts_\(suffix)" ("title");
                    -- migrate:down
                    DROP INDEX CONCURRENTLY "posts_\(suffix)_title";
                    """.write(to: directory.appendingPathComponent("\(ids[3]).sql"), atomically: true, encoding: .utf8)

                let runner = MigrationRunner(connection: db, sources: [
                    .prepared([
                        try MigrationCompiler.prepare(Shape(suffix: suffix)),
                        try MigrationCompiler.prepare(Reshape(suffix: suffix)),
                        try MigrationCompiler.prepare(ConcurrentIndex(suffix: suffix)),
                    ]),
                    .sqlDirectory(directory),
                ])
                try await runner.runMigrations()

                try await db.executeUpdate(sql: #"INSERT INTO "owners_\#(suffix)" VALUES (1)"#)
                try await db.executeUpdate(sql: #"INSERT INTO "posts_\#(suffix)" (id, title, views, owner_id, tags) VALUES (1, 'a', 50, 1, ARRAY['x'])"#)
                let mood = try await db.executeQuery(sql: #"SELECT mood::text AS mood FROM "posts_\#(suffix)""#) {
                    $0.makeRandomAccess()[data: "mood"].string
                }
                #expect(mood == ["happy"])
                for sql in [
                    #"INSERT INTO "posts_\#(suffix)" (id, title, views) VALUES (2, 'a', 1)"#,
                    #"INSERT INTO "posts_\#(suffix)" (id, views) VALUES (3, 1)"#,
                    #"INSERT INTO "posts_\#(suffix)" (id, title, views) VALUES (4, 'b', -1)"#,
                    #"INSERT INTO "posts_\#(suffix)" (id, title, owner_id) VALUES (5, 'c', 9)"#,
                    #"INSERT INTO "posts_\#(suffix)" (id, title, mood) VALUES (6, 'd', 'angry')"#,
                ] {
                    await #expect(throws: SpectroError.self) { try await db.executeUpdate(sql: sql) }
                }
                let indexes = try await db.executeQuery(sql: "SELECT indexname FROM pg_indexes WHERE tablename = 'posts_\(suffix)' ORDER BY indexname") {
                    $0.makeRandomAccess()[data: "indexname"].string
                }
                #expect(indexes.contains("posts_\(suffix)_views"))
                #expect(indexes.contains("posts_\(suffix)_title"))

                try await runner.runRollback(steps: 3)
                let columns = try await db.executeQuery(sql: """
                    SELECT column_name, data_type, is_nullable FROM information_schema.columns
                    WHERE table_name = 'entries_\(suffix)' ORDER BY column_name
                    """) { row -> String in
                    let row = row.makeRandomAccess()
                    return "\(row[data: "column_name"].string ?? "") \(row[data: "data_type"].string ?? "") \(row[data: "is_nullable"].string ?? "")"
                }
                #expect(columns.contains("legacy text YES"))
                #expect(columns.contains("views integer NO"))
                #expect(columns.contains("title text YES"))

                try await runner.runRollback(steps: 1)
                let leftovers = try await db.executeQuery(sql: "SELECT to_regclass('entries_\(suffix)') IS NULL AND to_regtype('mood_\(suffix)') IS NULL AS gone") {
                    $0.makeRandomAccess()[data: "gone"].bool
                }
                #expect(leftovers == [true])
            } catch {
                try? await db.executeUpdate(sql: #"DROP TABLE IF EXISTS "posts_\#(suffix)", "entries_\#(suffix)", "owners_\#(suffix)" CASCADE"#)
                try? await db.executeUpdate(sql: #"DROP TYPE IF EXISTS "mood_\#(suffix)""#)
                try? FileManager.default.removeItem(at: directory)
                try? await db.executeUpdate(sql: "DELETE FROM schema_migrations WHERE version IN ('\(ids.joined(separator: "','"))')")
                await db.shutdown()
                throw error
            }
            try? FileManager.default.removeItem(at: directory)
            await db.shutdown()
        }
    }
}

