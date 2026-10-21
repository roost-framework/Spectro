import Foundation
import Testing
@testable import Spectro

extension DatabaseIntegrationTests {
@Suite("Transaction isolation", .serialized)
struct TransactionIsolationTests {
    @Test("Transactions run at the requested isolation level")
    func levels() async throws {
        let repo = try await TestDatabase.sharedRepo()
        let level: @Sendable (any Repo) async throws -> String? = { tx in
            try await tx.executeRawQuery(sql: "SHOW transaction_isolation").first?.makeRandomAccess()[data: "transaction_isolation"].string
        }
        let readCommitted = try await repo.transaction(level)
        let repeatableRead = try await repo.transaction(isolation: .repeatableRead, level)
        let serializable = try await repo.transaction(isolation: .serializable, level)
        #expect(readCommitted == "read committed")
        #expect(repeatableRead == "repeatable read")
        #expect(serializable == "serializable")
    }

    @Test("A repeatable read transaction fails with SQLSTATE 40001 on a concurrent update")
    func concurrentUpdate() async throws {
        // Two connections: the transaction's, and one for the concurrent update.
        let spectro = try Spectro(configuration: DatabaseConfiguration(
            hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
            password: TestDatabase.password, database: TestDatabase.database,
            maxConnectionsPerEventLoop: 2, numberOfThreads: 1
        ))
        let repo = spectro.repository()
        do {
            try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "isolation_counters""#)
            try await repo.executeRawSQL(#"CREATE TABLE "isolation_counters" ("id" INTEGER PRIMARY KEY, "value" INTEGER NOT NULL)"#)
            try await repo.executeRawSQL(#"INSERT INTO "isolation_counters" VALUES (1, 0)"#)

            do {
                try await repo.transaction(isolation: .repeatableRead) { tx in
                    _ = try await tx.executeRawQuery(sql: #"SELECT "value" FROM "isolation_counters""#)
                    try await repo.executeRawSQL(#"UPDATE "isolation_counters" SET "value" = "value" + 1"#)
                    try await tx.executeRawSQL(#"UPDATE "isolation_counters" SET "value" = "value" + 10"#)
                }
                Issue.record("The transaction committed")
            } catch let error as SpectroError {
                #expect(error.serverError?.sqlState == "40001")
            }
            let value = try await repo.executeRawQuery(sql: #"SELECT "value" FROM "isolation_counters""#).first?.makeRandomAccess()[data: "value"].int
            #expect(value == 1)
        } catch {
            await spectro.shutdown()
            throw error
        }
        await spectro.shutdown()
    }
}
}
