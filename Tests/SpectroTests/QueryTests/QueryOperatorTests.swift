import Foundation
import Testing
import SpectroCommon
@testable import Spectro

/// Comprehensive tests for all QueryField operators.
/// This suite tests SQL generation for each operator without requiring a live database.
@Suite("Query Field Operators — SQL Generation", .serialized)
struct QueryOperatorTests {

    private func withQuery(_ body: (Query<TestUser>) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        let query = repo.query(TestUser.self)
        try await body(query)
    }

    // MARK: - Equality Operators

    @Test("Equal operator generates correct SQL")
    func equalOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" }.buildSQL()
            #expect(sql.contains("\"name\" = $1"))
        }
    }

    @Test("Not equal operator generates correct SQL")
    func notEqualOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name != "Alice" }.buildSQL()
            #expect(sql.contains("\"name\" != $1"))
        }
    }

    // MARK: - Comparison Operators

    @Test("Greater than operator")
    func greaterThanOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age > 18 }.buildSQL()
            #expect(sql.contains("\"age\" > $1"))
        }
    }

    @Test("Greater than or equal operator")
    func greaterThanOrEqualOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age >= 18 }.buildSQL()
            #expect(sql.contains("\"age\" >= $1"))
        }
    }

    @Test("Less than operator")
    func lessThanOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age < 65 }.buildSQL()
            #expect(sql.contains("\"age\" < $1"))
        }
    }

    @Test("Less than or equal operator")
    func lessThanOrEqualOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age <= 65 }.buildSQL()
            #expect(sql.contains("\"age\" <= $1"))
        }
    }

    // MARK: - String Pattern Matching (LIKE)

    @Test("LIKE operator")
    func likeOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.like("%alice%") }.buildSQL()
            #expect(sql.contains("\"name\" LIKE $1"))
        }
    }

    @Test("NOT LIKE operator")
    func notLikeOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.notLike("%admin%") }.buildSQL()
            #expect(sql.contains("\"name\" NOT LIKE $1"))
        }
    }

    @Test("ILIKE operator (case-insensitive)")
    func ilikeOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.ilike("%ALICE%") }.buildSQL()
            #expect(sql.contains("\"name\" ILIKE $1"))
        }
    }

    @Test("NOT ILIKE operator")
    func notIlikeOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.notIlike("%ADMIN%") }.buildSQL()
            #expect(sql.contains("\"name\" NOT ILIKE $1"))
        }
    }

    // MARK: - String Convenience Methods

    @Test("startsWith generates LIKE with trailing wildcard")
    func startsWithOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.startsWith("Ali") }.buildSQL()
            #expect(sql.contains("\"name\" LIKE $1"))
        }
    }

    @Test("endsWith generates LIKE with leading wildcard")
    func endsWithOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.endsWith("ice") }.buildSQL()
            #expect(sql.contains("\"name\" LIKE $1"))
        }
    }

    @Test("contains generates LIKE with both wildcards")
    func containsOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.contains("lic") }.buildSQL()
            #expect(sql.contains("\"name\" LIKE $1"))
        }
    }

    @Test("iStartsWith generates ILIKE with trailing wildcard")
    func iStartsWithOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.iStartsWith("ALI") }.buildSQL()
            #expect(sql.contains("\"name\" ILIKE $1"))
        }
    }

    @Test("iEndsWith generates ILIKE with leading wildcard")
    func iEndsWithOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.iEndsWith("ICE") }.buildSQL()
            #expect(sql.contains("\"name\" ILIKE $1"))
        }
    }

    @Test("iContains generates ILIKE with both wildcards")
    func iContainsOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.iContains("LIC") }.buildSQL()
            #expect(sql.contains("\"name\" ILIKE $1"))
        }
    }

    // MARK: - IN / NOT IN Operators

    @Test("IN clause with multiple values")
    func inOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.in(["Alice", "Bob", "Charlie"]) }.buildSQL()
            #expect(sql.contains("\"name\" IN ($1, $2, $3)"))
        }
    }

    @Test("NOT IN clause with multiple values")
    func notInOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.notIn(["Admin", "Root"]) }.buildSQL()
            #expect(sql.contains("\"name\" NOT IN ($1, $2)"))
        }
    }

    @Test("IN clause with integers")
    func inOperatorWithIntegers() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age.in([18, 21, 25, 30]) }.buildSQL()
            #expect(sql.contains("\"age\" IN ($1, $2, $3, $4)"))
        }
    }

    // MARK: - BETWEEN Operator

    @Test("BETWEEN clause for numeric range")
    func betweenOperatorNumeric() async throws {
        try await withQuery { q in
            let sql = q.where { $0.age.between(18, and: 65) }.buildSQL()
            #expect(sql.contains("\"age\" BETWEEN $1 AND $2"))
        }
    }

    // MARK: - NULL Checks

    @Test("IS NULL check")
    func isNullOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.isNull() }.buildSQL()
            #expect(sql.contains("\"name\" IS NULL"))
        }
    }

    @Test("IS NOT NULL check")
    func isNotNullOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.isNotNull() }.buildSQL()
            #expect(sql.contains("\"name\" IS NOT NULL"))
        }
    }

    // MARK: - Logical Operators

    @Test("AND operator combines conditions")
    func andOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" && $0.age > 18 }.buildSQL()
            #expect(sql.contains("(\"test_users\".\"name\" = $1) AND (\"test_users\".\"age\" > $2)"))
        }
    }

    @Test("OR operator combines conditions")
    func orOperator() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name == "Alice" || $0.name == "Bob" }.buildSQL()
            #expect(sql.contains("(\"test_users\".\"name\" = $1) OR (\"test_users\".\"name\" = $2)"))
        }
    }

    @Test("NOT operator negates condition")
    func notOperator() async throws {
        try await withQuery { q in
            let sql = q.where { !($0.isActive == true) }.buildSQL()
            #expect(sql.contains("NOT (\"test_users\".\"is_active\" = $1)"))
        }
    }

    @Test("Complex nested logical conditions")
    func complexLogicalConditions() async throws {
        try await withQuery { q in
            let sql = q.where {
                ($0.name == "Alice" || $0.name == "Bob") && $0.age >= 18
            }.buildSQL()
            #expect(sql.contains("AND"))
            #expect(sql.contains("OR"))
        }
    }

    // MARK: - Column Name Quoting

    @Test("Snake case column names are quoted")
    func snakeCaseQuoting() async throws {
        try await withQuery { q in
            let sql = q.where { $0.isActive == true }.buildSQL()
            #expect(sql.contains("\"is_active\""))
        }
    }

    @Test("Table name is quoted in FROM clause")
    func tableNameQuoting() async throws {
        try await withQuery { q in
            let sql = q.buildSQL()
            #expect(sql.contains("FROM \"test_users\""))
        }
    }

    @Test("createdAt maps to created_at and is quoted")
    func timestampColumnQuoting() async throws {
        try await withQuery { q in
            let sql = q.orderBy { $0.createdAt }.buildSQL()
            #expect(sql.contains("\"created_at\""))
        }
    }

    // MARK: - Edge Cases

    @Test("Empty IN clause produces FALSE")
    func emptyInClause() async throws {
        try await withQuery { q in
            let emptyArray: [String] = []
            let sql = q.where { $0.name.in(emptyArray) }.buildSQL()
            #expect(sql.contains("FALSE"))
        }
    }

    @Test("Single value IN clause")
    func singleValueInClause() async throws {
        try await withQuery { q in
            let sql = q.where { $0.name.in(["Alice"]) }.buildSQL()
            #expect(sql.contains("\"name\" IN ($1)"))
        }
    }

    @Test("Boolean equality check")
    func booleanEquality() async throws {
        try await withQuery { q in
            let sqlTrue = q.where { $0.isActive == true }.buildSQL()
            let sqlFalse = q.where { $0.isActive == false }.buildSQL()
            #expect(sqlTrue.contains("\"is_active\" = $1"))
            #expect(sqlFalse.contains("\"is_active\" = $1"))
        }
    }

    // MARK: - Chained Conditions

    @Test("Multiple chained where clauses use AND")
    func chainedWhereClausesUseAnd() async throws {
        try await withQuery { q in
            let sql = q
                .where { $0.name == "Alice" }
                .where { $0.age > 18 }
                .where { $0.isActive == true }
                .buildSQL()
            
            // Should have AND between each condition
            #expect(sql.contains("\"name\" = $1"))
            #expect(sql.contains("AND"))
            #expect(sql.contains("\"age\" > $2"))
            #expect(sql.contains("\"is_active\" = $3"))
        }
    }

    @Test("Placeholder numbering is sequential")
    func sequentialPlaceholderNumbering() async throws {
        try await withQuery { q in
            let sql = q
                .where { $0.name.in(["A", "B"]) }
                .where { $0.age.between(18, and: 65) }
                .buildSQL()
            
            #expect(sql.contains("$1"))
            #expect(sql.contains("$2"))
            #expect(sql.contains("$3"))
            #expect(sql.contains("$4"))
            #expect(!sql.contains("?"))  // No raw placeholders should remain
        }
    }
}
