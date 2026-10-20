import Foundation
import Testing
@testable import Spectro

@Schema("sandbox_items")
struct SandboxItem {
    @ID var id: UUID
    @Column var name: String
}

extension DatabaseIntegrationTests {
@Suite("Test sandbox", .serialized)
struct SandboxTests {
    private func withSpectro(_ body: (Spectro) async throws -> Void) async throws {
        let setup = try await TestDatabase.sharedRepo()
        try await setup.executeRawSQL(#"DROP TABLE IF EXISTS "sandbox_items""#)
        try await setup.executeRawSQL(#"CREATE TABLE "sandbox_items" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL UNIQUE)"#)
        let config = DatabaseConfiguration(
            hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
            password: TestDatabase.password, database: TestDatabase.database,
            maxConnectionsPerEventLoop: 2, numberOfThreads: 1
        )
        let spectro = try Spectro(configuration: config)
        do {
            try await body(spectro)
        } catch {
            await spectro.shutdown()
            throw error
        }
        await spectro.shutdown()
    }

    private func committedCount() async throws -> Int {
        try await TestDatabase.sharedRepo().query(SandboxItem.self).count()
    }

    @Test("Writes are visible to every repository of the instance and discarded afterwards")
    func discarded() async throws {
        try await withSpectro { spectro in
            let names = try await spectro.sandbox { repo in
                _ = try await repo.insert(SandboxItem(name: "a"))
                // Code under test that makes its own repository sees the same transaction.
                _ = try await spectro.repository().insert(SandboxItem(name: "b"))
                async let fromChildTask = spectro.repository().query(SandboxItem.self).count()
                #expect(try await fromChildTask == 2)
                // Other pools, like the shared test connection, see nothing uncommitted.
                #expect(try await committedCount() == 0)
                return try await repo.query(SandboxItem.self).orderBy { $0.name }.all().map(\.name)
            }
            #expect(names == ["a", "b"])
            #expect(try await committedCount() == 0)
            #expect(try await spectro.repository().query(SandboxItem.self).count() == 0)
        }
    }

    @Test("Transactions in a sandbox are savepoints that commit to it or roll back alone")
    func nestedTransactions() async throws {
        try await withSpectro { spectro in
            try await spectro.sandbox { repo in
                try await repo.transaction { tx in
                    _ = try await tx.insert(SandboxItem(name: "kept"))
                }
                do {
                    try await spectro.transaction { tx in
                        _ = try await tx.insert(SandboxItem(name: "dropped"))
                        _ = try await tx.insert(SandboxItem(name: "kept"))
                    }
                    Issue.record("A duplicate name was inserted")
                } catch let error as SpectroError {
                    guard case .transactionFailed = error else {
                        Issue.record("Unexpected error \(error)")
                        return
                    }
                    #expect(error.serverError?.sqlState == "23505")
                }
                // The failed savepoint left the sandbox usable.
                let names = try await repo.query(SandboxItem.self).all().map(\.name)
                #expect(names == ["kept"])
            }
            #expect(try await committedCount() == 0)
        }
    }

    @Test("An error thrown in the sandbox is rethrown after the rollback")
    func errors() async throws {
        try await withSpectro { spectro in
            await #expect(throws: CancellationError.self) {
                try await spectro.sandbox { repo in
                    _ = try await repo.insert(SandboxItem(name: "x"))
                    throw CancellationError()
                }
            }
            #expect(try await committedCount() == 0)
            // The pool is usable after the sandbox ends.
            _ = try await spectro.repository().insert(SandboxItem(name: "after"))
            #expect(try await committedCount() == 1)
        }
    }

    @Test("A task that outlives its sandbox fails instead of writing to the database")
    func outlivingTask() async throws {
        try await withSpectro { spectro in
            let stray = try await spectro.sandbox { repo in
                Task {
                    try await Task.sleep(for: .milliseconds(100))
                    _ = try await repo.insert(SandboxItem(name: "stray"))
                }
            }
            await #expect(throws: SpectroError.self) { try await stray.value }
            #expect(try await committedCount() == 0)
        }
    }

    @Test("Concurrent transactions in a sandbox take turns, so one rollback cannot undo another")
    func concurrentTransactions() async throws {
        try await withSpectro { spectro in
            try await spectro.sandbox { repo in
                async let failing: Void = repo.transaction { tx in
                    _ = try await tx.insert(SandboxItem(name: "undone"))
                    try await Task.sleep(for: .milliseconds(50))
                    throw CancellationError()
                }
                async let succeeding: Void = repo.transaction { tx in
                    _ = try await tx.insert(SandboxItem(name: "kept"))
                    try await Task.sleep(for: .milliseconds(50))
                }
                _ = try? await failing
                try await succeeding
                let names = try await repo.query(SandboxItem.self).all().map(\.name)
                #expect(names == ["kept"])
            }
        }
    }
}
}
