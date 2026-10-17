import Foundation
import Testing
@testable import Spectro

extension DatabaseIntegrationTests {
@Suite("Repository CRUD")
struct RepositoryTests {

    private func withCleanTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
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
        try await body(repo)
    }

    @Test("Insert and get by ID")
    func insertAndGet() async throws {
        try await withCleanTable { repo in
            let user = TestUser(name: "Alice", email: "alice@test.com", age: 30)
            let inserted = try await repo.insert(user)

            #expect(inserted.name == "Alice")
            #expect(inserted.email == "alice@test.com")
            #expect(inserted.age == 30)

            let fetched = try await repo.get(TestUser.self, id: inserted.id)
            #expect(fetched != nil)
            #expect(fetched?.name == "Alice")
        }
    }

    @Test("Get returns nil for non-existent ID")
    func getReturnsNil() async throws {
        try await withCleanTable { repo in
            let result = try await repo.get(TestUser.self, id: UUID())
            #expect(result == nil)
        }
    }

    @Test("All returns all rows")
    func allReturnsRows() async throws {
        try await withCleanTable { repo in
            let _ = try await repo.insert(TestUser(name: "Alice", email: "a@test.com", age: 25))
            let _ = try await repo.insert(TestUser(name: "Bob", email: "b@test.com", age: 30))

            let all = try await repo.all(TestUser.self)
            #expect(all.count == 2)
        }
    }

    @Test("Update modifies fields")
    func updateFields() async throws {
        try await withCleanTable { repo in
            let user = try await repo.insert(TestUser(name: "Alice", email: "a@test.com", age: 25))

            let updated = try await repo.update(TestUser.self, id: user.id, changes: [
                "name": "Alicia",
                "age": 26,
            ])

            #expect(updated.name == "Alicia")
            #expect(updated.age == 26)
            #expect(updated.email == "a@test.com")
        }
    }

    @Test("Update of a missing ID throws notFound")
    func updateMissingThrowsNotFound() async throws {
        try await withCleanTable { repo in
            do {
                _ = try await repo.update(TestUser.self, id: UUID(), changes: ["name": "Nobody"])
                Issue.record("Expected SpectroError.notFound to be thrown")
            } catch let error as SpectroError {
                guard case .notFound = error else {
                    Issue.record("Expected SpectroError.notFound but got: \(error)")
                    return
                }
            }
        }
    }

    @Test("Delete removes a row")
    func deleteRow() async throws {
        try await withCleanTable { repo in
            let user = try await repo.insert(TestUser(name: "Alice", email: "a@test.com", age: 25))
            try await repo.delete(TestUser.self, id: user.id)

            let fetched = try await repo.get(TestUser.self, id: user.id)
            #expect(fetched == nil)
        }
    }

    @Test("Delete non-existent ID succeeds silently")
    func deleteNonExistent() async throws {
        try await withCleanTable { repo in
            // GenericDatabaseRepo.delete uses executeUpdate which doesn't check affected rows
            try await repo.delete(TestUser.self, id: UUID())
            // Verify table is still empty (nothing was deleted)
            let all = try await repo.all(TestUser.self)
            #expect(all.isEmpty)
        }
    }

    @Test("getOrFail throws for missing ID")
    func getOrFailThrows() async throws {
        try await withCleanTable { repo in
            do {
                let _ = try await repo.getOrFail(TestUser.self, id: UUID())
                Issue.record("Expected SpectroError.notFound to be thrown")
            } catch is SpectroError {
                // Expected
            }
        }
    }
}
}
