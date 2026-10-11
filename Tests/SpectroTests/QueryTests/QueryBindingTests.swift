import Testing
import Foundation
import PostgresKit
@testable import Spectro

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
