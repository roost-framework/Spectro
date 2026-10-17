import Foundation
import Testing
@testable import Spectro

@Schema("savepoint_items")
private struct SavepointItem {
    @ID var id: UUID
    @Column var name: String
}

private struct Rejected: Error {}

extension DatabaseIntegrationTests {
    @Suite("Savepoints")
    struct SavepointTests {

        private func withCleanTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS "savepoint_items" (
                    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    "name" TEXT NOT NULL UNIQUE
                )
            """)
            try await repo.executeRawSQL(#"TRUNCATE "savepoint_items""#)
            try await body(repo)
        }

        private func names(_ repo: GenericDatabaseRepo) async throws -> [String] {
            try await repo.all(SavepointItem.self).map(\.name).sorted()
        }

        @Test("A failed statement in a savepoint leaves the transaction usable")
        func failedStatementRollsBackToSavepoint() async throws {
            try await withCleanTable { repo in
                try await repo.transaction { repo in
                    let tx = try #require(repo as? TransactionRepo)
                    _ = try await tx.insert(SavepointItem(name: "before"))
                    do {
                        _ = try await tx.savepoint { sp in
                            _ = try await sp.insert(SavepointItem(name: "inside"))
                            return try await sp.insert(SavepointItem(name: "before"))
                        }
                        Issue.record("Expected a unique violation")
                    } catch let error as SpectroError {
                        if case .queryExecutionFailed = error {} else {
                            Issue.record("Expected queryExecutionFailed, got \(error)")
                        }
                    }
                    // Without the savepoint, PostgreSQL would reject this with 25P02.
                    _ = try await tx.insert(SavepointItem(name: "after"))
                }
                #expect(try await names(repo) == ["after", "before"])
            }
        }

        @Test("A savepoint rethrows the body's error unchanged and rolls back its writes")
        func bodyErrorRethrownUnchanged() async throws {
            try await withCleanTable { repo in
                try await repo.transaction { repo in
                    let tx = try #require(repo as? TransactionRepo)
                    await #expect(throws: Rejected.self) {
                        try await tx.savepoint { sp -> Void in
                            _ = try await sp.insert(SavepointItem(name: "rejected"))
                            throw Rejected()
                        }
                    }
                    _ = try await tx.insert(SavepointItem(name: "kept"))
                }
                #expect(try await names(repo) == ["kept"])
            }
        }

        @Test("A savepoint's writes commit with the transaction")
        func savepointCommits() async throws {
            try await withCleanTable { repo in
                let item: SavepointItem = try await repo.transaction { repo in
                    let tx = try #require(repo as? TransactionRepo)
                    return try await tx.savepoint { sp in
                        try await sp.insert(SavepointItem(name: "saved"))
                    }
                }
                #expect(item.name == "saved")
                #expect(try await names(repo) == ["saved"])
            }
        }

        @Test("Nested savepoints roll back the inner failure and keep the outer work")
        func nestedSavepoints() async throws {
            try await withCleanTable { repo in
                try await repo.transaction { repo in
                    let tx = try #require(repo as? TransactionRepo)
                    try await tx.savepoint { outer -> Void in
                        _ = try await outer.insert(SavepointItem(name: "outer"))
                        await #expect(throws: Rejected.self) {
                            try await outer.savepoint { inner -> Void in
                                _ = try await inner.insert(SavepointItem(name: "inner"))
                                throw Rejected()
                            }
                        }
                        _ = try await outer.insert(SavepointItem(name: "outer-after"))
                    }
                }
                #expect(try await names(repo) == ["outer", "outer-after"])
            }
        }

        @Test("transaction() inside a transaction still throws transactionAlreadyStarted")
        func nestedTransactionStillThrows() async throws {
            try await withCleanTable { repo in
                try await repo.transaction { tx in
                    do {
                        try await tx.transaction { _ in () }
                        Issue.record("Expected transactionAlreadyStarted")
                    } catch SpectroError.transactionAlreadyStarted {
                        // Expected: savepoint(_:) is the nesting mechanism.
                    }
                }
            }
        }
    }
}
