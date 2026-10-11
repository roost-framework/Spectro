import Foundation
import Testing
import SpectroCommon
@testable import Spectro

extension DatabaseIntegrationTests {
@Suite("Query Execution")
struct QueryExecutionTests {

    private func withSeededTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS "test_users" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL DEFAULT '',
                "email" TEXT NOT NULL DEFAULT '',
                "age" INT NOT NULL DEFAULT 0,
                "is_active" BOOLEAN NOT NULL DEFAULT true,
                "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)
        try await repo.executeRawSQL("TRUNCATE \"test_users\"")
        let _ = try await repo.insert(TestUser(name: "Alice", email: "alice@test.com", age: 30, isActive: true))
        let _ = try await repo.insert(TestUser(name: "Bob", email: "bob@test.com", age: 25, isActive: true))
        let _ = try await repo.insert(TestUser(name: "Charlie", email: "charlie@test.com", age: 35, isActive: false))
        try await body(repo)
    }

    @Test("Query.all returns all rows")
    func queryAll() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self).all()
            #expect(users.count == 3)
        }
    }

    @Test("Query.first returns one row")
    func queryFirst() async throws {
        try await withSeededTable { repo in
            let user = try await repo.query(TestUser.self).first()
            #expect(user != nil)
        }
    }

    @Test("Query.count returns total rows")
    func queryCount() async throws {
        try await withSeededTable { repo in
            let count = try await repo.query(TestUser.self).count()
            #expect(count == 3)
        }
    }

    @Test("Where clause filters results")
    func whereFilter() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.name == "Alice" }
                .all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
        }
    }

    @Test("A where clause chained after an OR excludes rows it does not match")
    func chainedWhereAfterOr() async throws {
        try await withSeededTable { repo in
            let query = repo.query(TestUser.self)
                .where { $0.name == "Charlie" || $0.name == "Alice" }
                .where { $0.isActive == true }
            let users = try await query.all()
            let count = try await query.count()
            #expect(users.map(\.name) == ["Alice"])
            #expect(count == 1)
        }
    }

    @Test("Where clause with comparison operators")
    func whereComparison() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.age > 28 }
                .all()
            #expect(users.count == 2)
        }
    }

    @Test("Compound where with AND")
    func compoundWhereAnd() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.age > 20 && $0.isActive == true }
                .all()
            #expect(users.count == 2)
        }
    }

    @Test("OrderBy sorts results")
    func orderBy() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .orderBy({ $0.age }, .asc)
                .all()
            #expect(users.first?.name == "Bob")
            #expect(users.last?.name == "Charlie")
        }
    }

    @Test("OrderBy descending")
    func orderByDesc() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .orderBy({ $0.age }, .desc)
                .all()
            #expect(users.first?.name == "Charlie")
        }
    }

    @Test("Limit restricts result count")
    func limitResults() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .limit(2)
                .all()
            #expect(users.count == 2)
        }
    }

    @Test("Offset skips rows")
    func offsetResults() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .orderBy({ $0.age }, .asc)
                .offset(1)
                .limit(1)
                .all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
        }
    }

    @Test("IN clause filters by set")
    func inClause() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.name.in(["Alice", "Charlie"]) }
                .all()
            #expect(users.count == 2)
        }
    }

    @Test("BETWEEN filters range")
    func betweenClause() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.age.between(26, and: 32) }
                .all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
        }
    }

    @Test("ILIKE case-insensitive search")
    func ilikeSearch() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.name.ilike("%alice%") }
                .all()
            #expect(users.count == 1)
        }
    }

    @Test("Count with where clause")
    func countWithWhere() async throws {
        try await withSeededTable { repo in
            let count = try await repo.query(TestUser.self)
                .where { $0.isActive == true }
                .count()
            #expect(count == 2)
        }
    }

    @Test("firstOrFail throws on empty result")
    func firstOrFailThrows() async throws {
        try await withSeededTable { repo in
            do {
                let _ = try await repo.query(TestUser.self)
                    .where { $0.name == "NonExistent" }
                    .firstOrFail()
                Issue.record("Expected SpectroError.notFound to be thrown")
            } catch let error as SpectroError {
                // Verify it is specifically .notFound, not a connection/query error
                // that would mask a pool shutdown race.
                guard case .notFound = error else {
                    Issue.record("Expected SpectroError.notFound but got: \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Nullable column tests

    private func withBioTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS "test_users_bio" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL DEFAULT '',
                "email" TEXT NOT NULL DEFAULT '',
                "bio" TEXT
            )
        """)
        try await repo.executeRawSQL("TRUNCATE \"test_users_bio\"")
        try await body(repo)
    }

    @Test("INSERT with nil optional column, SELECT returns nil")
    func nullableColumnNil() async throws {
        try await withBioTable { repo in
            let _ = try await repo.insert(TestUserWithBio(name: "Alice", email: "alice@test.com", bio: nil))
            let users = try await repo.query(TestUserWithBio.self).all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
            #expect(users.first?.bio == nil)
        }
    }

    @Test("INSERT with non-nil optional column, SELECT returns value")
    func nullableColumnNonNil() async throws {
        try await withBioTable { repo in
            let _ = try await repo.insert(TestUserWithBio(name: "Bob", email: "bob@test.com", bio: "Hello world"))
            let users = try await repo.query(TestUserWithBio.self).all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Bob")
            #expect(users.first?.bio == "Hello world")
        }
    }

    // MARK: - @Schema macro integration tests

    private func withMacroUserTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS "test_macro_users" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL DEFAULT '',
                "email" TEXT NOT NULL DEFAULT '',
                "bio" TEXT,
                "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)
        try await repo.executeRawSQL("TRUNCATE \"test_macro_users\"")
        try await body(repo)
    }

    @Test("Macro-generated schema INSERT and SELECT round-trip")
    func macroInsertSelect() async throws {
        try await withMacroUserTable { repo in
            let _ = try await repo.insert(TestMacroUser(name: "Alice", email: "alice@test.com", bio: "Hello"))
            let users = try await repo.query(TestMacroUser.self).all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
            #expect(users.first?.email == "alice@test.com")
            #expect(users.first?.bio == "Hello")
        }
    }

    @Test("Macro-generated schema handles nil optional column")
    func macroNilColumn() async throws {
        try await withMacroUserTable { repo in
            let _ = try await repo.insert(TestMacroUser(name: "Bob", email: "bob@test.com"))
            let users = try await repo.query(TestMacroUser.self).all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Bob")
            #expect(users.first?.bio == nil)
        }
    }

    @Test("Chaining where, orderBy, limit together")
    func fullChain() async throws {
        try await withSeededTable { repo in
            let users = try await repo.query(TestUser.self)
                .where { $0.isActive == true }
                .orderBy({ $0.age }, .desc)
                .limit(1)
                .all()
            #expect(users.count == 1)
            #expect(users.first?.name == "Alice")
        }
    }
}
}
