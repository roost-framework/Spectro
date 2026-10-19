import Foundation
import Testing
import SpectroCommon
@testable import Spectro

@Suite("Query Builder — SQL Generation", .serialized)
struct QueryTests {

    private func withQuery(_ body: (Query<TestUser>) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        let query = repo.query(TestUser.self)
        try await body(query)
    }

    // MARK: - Basic SQL

    @Test("Bare query generates SELECT * FROM table")
    func bareQuery() async throws {
        try await withQuery { q in
            #expect(q.buildSQL() == "SELECT * FROM \"test_users\"")
        }
    }

    // MARK: - Where Clauses

    @Test("Single where clause")
    func singleWhere() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" }.buildSQL()
            #expect(sql.contains("WHERE"))
            #expect(sql.contains("\"name\" = $1"))
        }
    }

    @Test("Chained where clauses use AND")
    func chainedWhere() async throws {
        try await withQuery { q in
            let sql = q
                .where { $0.name == "Alice" }
                .where { $0.age > 18 }
                .buildSQL()
            #expect(sql.contains("AND"))
            #expect(sql.contains("\"name\" = $1"))
            #expect(sql.contains("\"age\" > $2"))
        }
    }

    @Test("Compound conditions with &&")
    func compoundConditions() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" && $0.age > 18 }.buildSQL()
            #expect(sql.contains("AND"))
        }
    }

    @Test("OR conditions")
    func orConditions() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" || $0.name == "Bob" }.buildSQL()
            #expect(sql.contains("OR"))
        }
    }

    @Test("NOT condition")
    func notCondition() async throws {
        try await withQuery { q in
            let sql = q.where { !($0.isActive == true) }.buildSQL()
            #expect(sql.contains("NOT"))
        }
    }

    // MARK: - Ordering

    @Test("Single orderBy defaults to ASC")
    func orderByDefault() async throws {
        try await withQuery { q in
            let sql = q.orderBy { $0.name }.buildSQL()
            #expect(sql.contains("ORDER BY \"test_users\".\"name\" ASC"))
        }
    }

    @Test("OrderBy with explicit direction")
    func orderByDirection() async throws {
        try await withQuery { q in
            let sql = q.orderBy({ $0.age }, .desc).buildSQL()
            #expect(sql.contains("ORDER BY \"test_users\".\"age\" DESC"))
        }
    }

    @Test("Multi-field orderBy")
    func multiOrderBy() async throws {
        try await withQuery { q in
            let sql = q.orderBy({ $0.name }, .asc, then: { $0.age }, .desc).buildSQL()
            #expect(sql.contains("ORDER BY \"test_users\".\"name\" ASC, \"test_users\".\"age\" DESC"))
        }
    }

    // MARK: - Pagination

    @Test("Limit clause")
    func limitClause() async throws {
        try await withQuery { q in
            #expect(q.limit(10).buildSQL().contains("LIMIT 10"))
        }
    }

    @Test("Offset clause")
    func offsetClause() async throws {
        try await withQuery { q in
            #expect(q.offset(20).buildSQL().contains("OFFSET 20"))
        }
    }

    @Test("Limit and offset together")
    func limitAndOffset() async throws {
        try await withQuery { q in
            let sql = q.limit(10).offset(20).buildSQL()
            #expect(sql.contains("LIMIT 10"))
            #expect(sql.contains("OFFSET 20"))
        }
    }

    // MARK: - String Operators

    @Test("LIKE operator")
    func likeOperator() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.like("%alice%") }.buildSQL().contains("LIKE"))
        }
    }

    @Test("ILIKE operator")
    func ilikeOperator() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.ilike("%alice%") }.buildSQL().contains("ILIKE"))
        }
    }

    @Test("contains generates LIKE with wildcards")
    func containsOperator() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.contains("ali") }.buildSQL().contains("LIKE"))
        }
    }

    @Test("startsWith generates LIKE with trailing wildcard")
    func startsWithOperator() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.startsWith("ali") }.buildSQL().contains("LIKE"))
        }
    }

    // MARK: - NULL Checks

    @Test("IS NULL check")
    func isNullCheck() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.isNull() }.buildSQL().contains("IS NULL"))
        }
    }

    @Test("IS NOT NULL check")
    func isNotNullCheck() async throws {
        try await withQuery { q in
            #expect(q.where { $0.name.isNotNull() }.buildSQL().contains("IS NOT NULL"))
        }
    }

    // MARK: - IN Operator

    @Test("IN clause generates correct SQL")
    func inClause() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.in(["Alice", "Bob", "Charlie"]) }.buildSQL()
            #expect(sql.contains("IN"))
            #expect(sql.contains("$1"))
            #expect(sql.contains("$2"))
            #expect(sql.contains("$3"))
        }
    }

    // MARK: - BETWEEN Operator

    @Test("BETWEEN clause")
    func betweenClause() async throws {
        try await withQuery { q in
            #expect(q.where { $0.age.between(18, and: 65) }.buildSQL().contains("BETWEEN"))
        }
    }

    // MARK: - Count SQL

    @Test("Count query generates SELECT COUNT(*)")
    func countSQL() async throws {
        try await withQuery { q in
            let sql = q.buildCountSQL()
            #expect(sql.contains("SELECT COUNT(*) as count"))
            #expect(sql.contains("FROM \"test_users\""))
        }
    }

    // MARK: - Joins

    @Test("Inner join generates correct SQL")
    func innerJoin() async throws {
        try await withQuery { q in
            let sql = q.join(TestPost.self, on: { $0.left.id == $0.right.userId }).buildSQL()
            #expect(sql.contains("INNER JOIN"))
            #expect(sql.contains("\"test_posts\""))
        }
    }

    @Test("Left join generates correct SQL")
    func leftJoin() async throws {
        try await withQuery { q in
            let sql = q.leftJoin(TestPost.self, on: { $0.left.id == $0.right.userId }).buildSQL()
            #expect(sql.contains("LEFT JOIN"))
        }
    }

    // MARK: - Placeholder Renumbering

    @Test("Placeholders are numbered sequentially across conditions")
    func placeholderRenumbering() async throws {
        try await withQuery { q in
            let sql = q
                .where { $0.name == "Alice" }
                .where { $0.age > 18 }
                .where { $0.isActive == true }
                .buildSQL()
            #expect(sql.contains("$1"))
            #expect(sql.contains("$2"))
            #expect(sql.contains("$3"))
            #expect(!sql.contains("?"))
        }
    }

    // MARK: - Query Immutability

    @Test("Query is a value type — modifications don't affect original")
    func queryImmutability() async throws {
        try await withQuery { base in
            let filtered = base.where { $0.name == "Alice" }
            let ordered = base.orderBy { $0.name }

            #expect(!base.buildSQL().contains("WHERE"))
            #expect(filtered.buildSQL().contains("WHERE"))
            #expect(!filtered.buildSQL().contains("ORDER BY"))
            #expect(ordered.buildSQL().contains("ORDER BY"))
            #expect(!ordered.buildSQL().contains("WHERE"))
        }
    }
}
