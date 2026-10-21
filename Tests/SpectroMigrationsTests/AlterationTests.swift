import Testing
import SpectroCommon
import SpectroMigrations

@Suite("Table alterations, types, and concurrent indexes")
struct AlterationTests {
    private func compile(_ migration: some Migration) throws -> (up: String, down: String) {
        let prepared = try MigrationCompiler.prepare(migration)
        guard case .sql(let down) = prepared.rollback else { throw MigrationPlanningError(reason: "Expected a rollback") }
        return (prepared.upSQL, down)
    }

    struct Reshape: Migration {
        static let id = "1700000100_reshape"
        var change: MigrationPlan {
            AlterTable("posts") { table in
                table.remove("legacy", .varchar(length: 20)).notNull().default("none").references("users", name: "legacy_fk")
                table.alter("views", type: .bigint, from: .integer)
                table.setNotNull("title")
                table.dropNotNull("subtitle")
                table.setDefault("status", "draft", from: nil)
                table.setDefault("score", nil, from: 0)
                table.check("views_positive", sql: "views >= 0")
                table.unique("posts_slug_key", columns: ["slug", "site_id"])
                table.foreignKey("author_id", references: "users", onDelete: .cascade)
            }
        }
    }

    @Test("Alterations render, and their rollback inverts them in reverse order")
    func alterations() throws {
        let (up, down) = try compile(Reshape())
        #expect(up.contains(#"ALTER TABLE "posts" DROP COLUMN "legacy""#))
        #expect(up.contains(#"ALTER COLUMN "views" TYPE BIGINT"#))
        #expect(up.contains(#"ALTER COLUMN "title" SET NOT NULL"#))
        #expect(up.contains(#"ALTER COLUMN "subtitle" DROP NOT NULL"#))
        #expect(up.contains(#"ALTER COLUMN "status" SET DEFAULT E'draft'"#))
        #expect(up.contains(#"ALTER COLUMN "score" DROP DEFAULT"#))
        #expect(up.contains(#"ADD CONSTRAINT "views_positive" CHECK (views >= 0"#))
        #expect(up.contains(#"ADD CONSTRAINT "posts_slug_key" UNIQUE ("slug", "site_id")"#))
        #expect(up.contains(#"ADD CONSTRAINT "posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "users" ("id") ON DELETE CASCADE"#))

        #expect(down.contains(#"ADD COLUMN "legacy" VARCHAR(20) NOT NULL DEFAULT E'none' CONSTRAINT "legacy_fk" REFERENCES "users" ("id") ON DELETE NO ACTION"#))
        #expect(down.contains(#"ALTER COLUMN "views" TYPE INTEGER"#))
        #expect(down.contains(#"ALTER COLUMN "title" DROP NOT NULL"#))
        #expect(down.contains(#"ALTER COLUMN "subtitle" SET NOT NULL"#))
        #expect(down.contains(#"ALTER COLUMN "status" DROP DEFAULT"#))
        #expect(down.contains(#"ALTER COLUMN "score" SET DEFAULT 0"#))
        #expect(down.contains(#"DROP CONSTRAINT "posts_author_id_fkey""#))
        let foreignKey = try #require(down.range(of: "posts_author_id_fkey"))
        let column = try #require(down.range(of: #"ADD COLUMN "legacy""#))
        #expect(foreignKey.lowerBound < column.lowerBound)
    }

    struct DropCheck: Migration {
        static let id = "1700000101_drop_check"
        var change: MigrationPlan { AlterTable("posts") { $0.dropConstraint("views_positive") } }
    }

    struct DropCheckExplicitly: Migration {
        static let id = "1700000102_drop_check_explicitly"
        var change: MigrationPlan {
            Reversible {
                AlterTable("posts") { $0.dropConstraint("views_positive") }
                DropIndex("posts_views_index")
            } down: {
                AlterTable("posts") { $0.check("views_positive", sql: "views >= 0") }
                CreateIndex("posts_views_index", on: "posts", columns: ["views"])
            }
        }
    }

    struct DropIndexAutomatically: Migration {
        static let id = "1700000103_drop_index"
        var change: MigrationPlan { DropIndex("posts_views_index") }
    }

    @Test("Dropping a constraint or an index needs an explicit branch")
    func explicitDrops() throws {
        #expect(throws: MigrationPlanningError.self) { try MigrationCompiler.prepare(DropCheck()) }
        #expect(throws: MigrationPlanningError.self) { try MigrationCompiler.prepare(DropIndexAutomatically()) }
        let (up, down) = try compile(DropCheckExplicitly())
        #expect(up.contains(#"ALTER TABLE "posts" DROP CONSTRAINT "views_positive""#))
        #expect(up.contains(#"DROP INDEX "posts_views_index""#))
        #expect(down.contains(#"ADD CONSTRAINT "views_positive" CHECK"#))
        #expect(down.contains(#"CREATE INDEX "posts_views_index""#))
    }

    struct TablesAndTypes: Migration {
        static let id = "1700000104_tables_and_types"
        var change: MigrationPlan {
            CreateEnum("mood", values: ["happy", "it's ok"])
            RenameTable("entries", to: "posts", schema: "blog")
            CreateTable("samples") { table in
                table.column("a", .smallint)
                table.column("b", .real)
                table.column("c", .doublePrecision)
                table.column("d", .date)
                table.column("e", .timestamp)
                table.column("f", .bytea)
                table.column("g", .json)
                table.column("h", .array(.text))
                table.column("i", .array(.varchar(length: 10)))
                table.column("j", .named("mood"))
                table.column("k", .named("citext", schema: "public"))
                table.column("l", .array(.named("mood")))
            }
        }
    }

    @Test("Enum types, table renames, and the added column types render")
    func tablesAndTypes() throws {
        let (up, down) = try compile(TablesAndTypes())
        #expect(up.contains(#"CREATE TYPE "mood" AS ENUM (E'happy', E'it''s ok')"#))
        #expect(up.contains(#"ALTER TABLE "blog"."entries" RENAME TO "posts""#))
        for column in [#""a" SMALLINT"#, #""b" REAL"#, #""c" DOUBLE PRECISION"#, #""d" DATE"#, #""e" TIMESTAMP"#,
                       #""f" BYTEA"#, #""g" JSON"#, #""h" TEXT[]"#, #""i" VARCHAR(10)[]"#, #""j" "mood""#,
                       #""k" "public"."citext""#, #""l" "mood"[]"#] {
            #expect(up.contains(column))
        }
        #expect(down.contains(#"ALTER TABLE "blog"."posts" RENAME TO "entries""#))
        #expect(down.hasSuffix(#"DROP TYPE "mood";"#))
    }

    struct EmptyEnum: Migration {
        static let id = "1700000105_empty_enum"
        var change: MigrationPlan { CreateEnum("mood", values: ["a", "a"]) }
    }

    @Test("An enum needs distinct labels")
    func enumLabels() {
        #expect(throws: MigrationPlanningError.self) { try MigrationCompiler.prepare(EmptyEnum()) }
    }

    struct ConcurrentInTransaction: Migration {
        static let id = "1700000106_concurrent_in_transaction"
        var change: MigrationPlan { CreateIndex("posts_title_index", on: "posts", columns: ["title"]).concurrently() }
    }

    struct Concurrent: Migration {
        static let id = "1700000107_concurrent"
        static let runsInTransaction = false
        var change: MigrationPlan {
            CreateIndex("posts_title_index", on: "posts", columns: ["title"]).unique().concurrently()
        }
    }

    @Test("Concurrent indexes need a migration outside a transaction")
    func concurrentIndexes() throws {
        #expect(throws: MigrationPlanningError.self) { try MigrationCompiler.prepare(ConcurrentInTransaction()) }
        let prepared = try MigrationCompiler.prepare(Concurrent())
        #expect(!prepared.runsInTransaction)
        #expect(prepared.upSQL.contains(#"CREATE UNIQUE INDEX CONCURRENTLY "posts_title_index" ON "posts" ("title")"#))
        guard case .sql(let down) = prepared.rollback else { Issue.record("Expected a rollback"); return }
        #expect(down.contains(#"DROP INDEX CONCURRENTLY "posts_title_index""#))
        #expect(try MigrationCompiler.prepare(Reshape()).runsInTransaction)
    }
}
