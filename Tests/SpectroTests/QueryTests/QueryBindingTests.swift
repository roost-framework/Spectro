import Testing
import Foundation
import PostgresKit
@testable import Spectro

@Schema("renamed_items")
private struct RenamedItem {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
    @Column("LegacyCode") var code: String = ""
    @ForeignKey("org_ref") var orgId: UUID
    @Column var viewCount: Int = 0
}

@Suite("Query binding order")
struct QueryBindingTests {
    private actor Recorder: QueryExecutor {
        var bindings: [[String]] = []
        var statements: [String] = []

        func executeQuery<T: Sendable>(
            sql: String, parameters: [PostgresData],
            resultMapper: @Sendable @escaping (PostgresRow) throws -> T
        ) async throws -> [T] {
            bindings.append(parameters.map { $0.string ?? "?" })
            statements.append(sql)
            return []
        }
    }

    private struct SoftPost: Schema {
        @ID var id: UUID
        @Column var views: Int = 0
        static let tableName = "soft_posts"
        static var softDeleteColumn: String? { "deleted_at" }
        init() {}
    }

    private struct KeylessPost: Schema {
        static let tableName = "keyless_posts"
        @Column var title: String = ""
        init() {}
    }

    @Test("Unsupported typed join shapes fail before executing SQL")
    func unsupportedJoinShapes() async throws {
        let recorder = Recorder()
        let base = Query(schema: TestUser.self, executor: recorder)
        #expect(throws: SpectroError.self) {
            try base.join(TestUser.self, on: { _ in QueryCondition(sql: "TRUE") })
                .executeJoin(with: TestUser.self)
        }
        #expect(throws: SpectroError.self) {
            try base.join(TestPost.self, on: { _ in QueryCondition(sql: "TRUE") })
                .join(TestPost.self, on: { _ in QueryCondition(sql: "TRUE") })
                .executeJoin(with: TestPost.self)
        }
        #expect(throws: SpectroError.self) {
            try base.leftJoin(KeylessPost.self, on: { _ in QueryCondition(sql: "TRUE") })
                .executeJoin(with: KeylessPost.self)
        }
        #expect(await recorder.statements.isEmpty)
    }

    @Test("Typed joins qualify the implicit soft-delete filter")
    func softDeleteJoin() async throws {
        let recorder = Recorder()
        let query = Query(schema: SoftUser.self, executor: recorder)
            .join(SoftPost.self, on: { _ in QueryCondition(sql: "TRUE") })
        _ = try await query.executeJoin(with: SoftPost.self).all()
        #expect(await recorder.statements.first?.contains("WHERE \"\(SoftUser.tableName)\".\"deleted_at\" IS NULL") == true)
    }

    @Test("Joined tables exclude their soft-deleted rows unless withDeleted")
    func softDeleteJoinedTable() async throws {
        let recorder = Recorder()
        let base = Query(schema: TestUser.self, executor: recorder)
        let on: (JoinBuilder<TestUser, SoftPost>) -> QueryCondition = { _ in QueryCondition(sql: "TRUE") }
        _ = try await base.join(SoftPost.self, on: on).count()
        _ = try await base.leftJoin(SoftPost.self, on: on).count()
        _ = try await base.rightJoin(SoftPost.self, on: on).count()
        _ = try await base.join(SoftPost.self, on: on).withDeleted().count()
        let statements = await recorder.statements
        let source = #"(SELECT * FROM "soft_posts" WHERE "deleted_at" IS NULL) AS "soft_posts" ON"#
        #expect(statements.count == 4)
        #expect(statements.prefix(3).allSatisfy { $0.contains(source) })
        #expect(statements.last?.contains(#"INNER JOIN "soft_posts" ON"#) == true)
    }

    @Test("Builders use the database names given to @Column and @ForeignKey")
    func columnNameOverrides() async throws {
        let recorder = Recorder()
        let base = Query(schema: RenamedItem.self, executor: recorder)
        _ = try await base.where { $0.name == "a" && $0.code.isNotNull() }.orderBy { $0.orgId }.all()
        _ = try await base.select { $0.name }.all()
        _ = try await base.groupBy { $0.code }.groupedSum { $0.viewCount }
        _ = try await base.join(TestUser.self, on: { $0.left.orgId == $0.right.id })
            .executeJoin(with: TestUser.self).where { $0.main.name == "a" }.all()
        let statements = await recorder.statements
        let sql = statements.joined(separator: "\n")
        for fragment in [
            #"("display_name" = $1) AND ("LegacyCode" IS NOT NULL)"#, #"ORDER BY "org_ref""#,
            #"SELECT "display_name" FROM"#, #"SUM("view_count")"#, #"GROUP BY "LegacyCode""#,
            #"ON "renamed_items"."org_ref" = "test_users"."id""#, #"("renamed_items"."display_name" = $1)"#,
        ] {
            #expect(sql.contains(fragment), "missing \(fragment)")
        }
        // The joined test_users table has its own "name" column, so check its statement qualified only.
        let unjoined = statements.dropLast().joined(separator: "\n")
        for property in ["name", "code", "legacy_code", "org_id"] {
            #expect(!unjoined.contains("\"\(property)\""), "property name \(property) used as a column")
            #expect(!sql.contains("\"renamed_items\".\"\(property)\""), "property name \(property) used as a column")
        }
    }

    @Test("A where clause chained after an OR still constrains every row")
    func chainedWhereAfterOr() async throws {
        let recorder = Recorder()
        let query = Query(schema: TestUser.self, executor: recorder)
            .where { $0.name == "Alice" || $0.name == "Bob" }
            .where { $0.isActive == true }
        let expected = #"WHERE (("name" = $1) OR ("name" = $2)) AND ("is_active" = $3)"#
        #expect(query.buildSQL().contains(expected))
        _ = try await query.count()
        #expect(await recorder.statements.first?.contains(expected) == true)
    }

    @Test("The soft-delete filter applies to both sides of an OR")
    func softDeleteAroundOr() {
        let query = Query(schema: SoftUser.self, executor: Recorder())
            .where { $0.name == "Alice" || $0.name == "Bob" }
        #expect(query.buildSQL().contains(#"WHERE "deleted_at" IS NULL AND (("name" = $1) OR ("name" = $2))"#))
    }

    @Test("A having clause chained after an OR still constrains every group")
    func chainedHavingAfterOr() async throws {
        let recorder = Recorder()
        _ = try await Query(schema: TestUser.self, executor: recorder)
            .groupBy { $0.name }
            .having { $0.name == "Alice" || $0.name == "Bob" }
            .having { $0.name != "Excluded" }
            .groupedCount()
        #expect(await recorder.statements.first?.contains(
            #"HAVING (("name" = $1) OR ("name" = $2)) AND ("name" != $3)"#
        ) == true)
    }

    @Test("Aggregates and selected fields exclude soft-deleted rows unless withDeleted")
    func softDeleteAggregatesAndSelect() async throws {
        let recorder = Recorder()
        let base = Query(schema: SoftPost.self, executor: recorder)
        for query in [base, base.withDeleted()] {
            _ = try await query.sum { $0.views }
            _ = try await query.groupBy { $0.views }.groupedCount()
            _ = try await query.select { $0.views }.all()
        }
        let statements = await recorder.statements
        #expect(statements.count == 6)
        #expect(statements.prefix(3).allSatisfy { $0.contains(#"WHERE "deleted_at" IS NULL"#) })
        #expect(statements.suffix(3).allSatisfy { !$0.contains("deleted_at") })
    }

    @Test("Join parameters precede filters regardless of builder call order")
    func bindingsFollowSQL() async throws {
        let recorder = Recorder()
        let base = Query(schema: TestUser.self, executor: recorder).where { $0.name == "Alice" }
        let query = base.join(TestPost.self, on: { $0.right.title == "Article" })
        #expect(query.buildSQL().contains("\"test_posts\".\"title\" = $1"))
        #expect(query.buildSQL().contains("\"name\" = $2"))
        _ = try await query.all()
        _ = try await query.count()
        _ = try await query.sum { $0.age }
        _ = try await query.select { $0.name }.all()
        _ = try await query.groupBy { $0.name }.having { $0.name != "Excluded" }.groupedCount()
        _ = try await query.executeJoin(with: TestPost.self).where { $0.joined.title == "Second" }.all()
        #expect(await recorder.bindings == [
            ["Article", "Alice"], ["Article", "Alice"], ["Article", "Alice"],
            ["Article", "Alice"], ["Article", "Alice", "Excluded"], ["Article", "Alice", "Second"]
        ])
        #expect(await recorder.statements.allSatisfy { !$0.contains("?") })
        #expect(base.parameters.map(\.string) == ["Alice"])
    }
}
