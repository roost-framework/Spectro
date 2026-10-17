import Foundation
import Testing
import PostgresKit
@testable import Spectro

@Schema("server_error_accounts")
private struct ServerErrorAccount {
    @ID var id: UUID
    @Column var email: String
}

// PostgresMessage.Error has no public initializer. Its wire-format parser, deprecated only as a
// PostgresMessageType witness, builds one without a server.
private protocol ServerErrorParsing {
    static func parse(from buffer: inout ByteBuffer) throws -> Self
}

extension PostgresMessage.Error: ServerErrorParsing {}

private func parsed<Message: ServerErrorParsing>(_: Message.Type, from buffer: inout ByteBuffer) throws -> Message {
    try Message.parse(from: &buffer)
}

private func legacyServerError(_ fields: [PostgresMessage.Error.Field: String]) throws -> PostgresError {
    var buffer = ByteBuffer()
    for (field, value) in fields {
        buffer.writeInteger(field.rawValue)
        buffer.writeNullTerminatedString(value)
    }
    return .server(try parsed(PostgresMessage.Error.self, from: &buffer))
}

@Suite("Server error extraction")
struct ServerErrorExtractionTests {
    private let uniqueViolation = DatabaseServerError(
        sqlState: "23505",
        message: #"duplicate key value violates unique constraint "accounts_email_key""#,
        constraintName: "accounts_email_key",
        detail: "Key (email)=(ada@test.com) already exists.",
        tableName: "accounts"
    )

    private func driverError() throws -> PostgresError {
        try legacyServerError([
            .severity: "ERROR",
            .sqlState: "23505",
            .message: #"duplicate key value violates unique constraint "accounts_email_key""#,
            .detail: "Key (email)=(ada@test.com) already exists.",
            .tableName: "accounts",
            .constraintName: "accounts_email_key",
        ])
    }

    @Test("Legacy server errors are read through every wrapper")
    func unwrapsWrappers() throws {
        let query = SpectroError.queryExecutionFailed(sql: "INSERT", error: try driverError())
        let notFound = SpectroError.notFound(schema: "accounts", id: "1")
        let wrapped: [SpectroError] = [
            query,
            .invalidSql(sql: "INSERT", error: try driverError()),
            .transactionFailed(underlying: query),
            .transactionAndRollbackFailed(original: query, rollback: notFound),
            .migrationFailed(version: "1", error: SpectroError.transactionFailed(underlying: query)),
            .connectionFailed(underlying: try driverError()),
        ]
        for error in wrapped {
            #expect(error.serverError == uniqueViolation, "\(error)")
        }
    }

    @Test("Errors without a server response have no server error")
    func nonServerErrors() throws {
        let notFound = SpectroError.notFound(schema: "accounts", id: "1")
        let query = SpectroError.queryExecutionFailed(sql: "INSERT", error: try driverError())
        let errors: [SpectroError] = [
            notFound,
            .transactionFailed(underlying: notFound),
            .queryExecutionFailed(sql: "SELECT 1", error: PostgresError.connectionClosed),
            .transactionAndRollbackFailed(original: notFound, rollback: query),
            .connectionPoolExhausted,
        ]
        for error in errors {
            #expect(error.serverError == nil, "\(error)")
        }
    }
}

extension DatabaseIntegrationTests {
    @Suite("Server errors")
    struct ServerErrorTests {
        private func withAccounts(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS server_error_accounts (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    email TEXT NOT NULL,
                    CONSTRAINT server_error_accounts_email_key UNIQUE (email)
                )
                """)
            try await repo.executeRawSQL("TRUNCATE server_error_accounts")
            try await body(repo)
        }

        private func caughtServerError(_ body: () async throws -> Void) async -> DatabaseServerError? {
            do {
                try await body()
                Issue.record("Expected the statement to fail")
            } catch let error as SpectroError {
                return error.serverError
            } catch {
                Issue.record("Expected a SpectroError, got \(error)")
            }
            return nil
        }

        @Test("Unique violations expose SQLSTATE and constraint, inside transactions too")
        func uniqueViolation() async throws {
            try await withAccounts { repo in
                _ = try await repo.insert(ServerErrorAccount(email: "ada@test.com"))

                let errors: [(String, DatabaseServerError?)] = [
                    ("insert", await caughtServerError {
                        _ = try await repo.insert(ServerErrorAccount(email: "ada@test.com"))
                    }),
                    ("transaction", await caughtServerError {
                        try await repo.transaction { transaction in
                            _ = try await transaction.insert(ServerErrorAccount(email: "ada@test.com"))
                        }
                    }),
                    ("raw SQL", await caughtServerError {
                        try await repo.executeRawSQL("INSERT INTO server_error_accounts (email) VALUES ('ada@test.com')")
                    }),
                ]
                for (path, error) in errors {
                    #expect(error?.sqlState == "23505", "\(path)")
                    #expect(error?.constraintName == "server_error_accounts_email_key", "\(path)")
                    #expect(error?.tableName == "server_error_accounts", "\(path)")
                }
            }
        }

        @Test("Not-null violations expose the column")
        func notNullViolation() async throws {
            try await withAccounts { repo in
                let error = await caughtServerError {
                    try await repo.executeRawSQL("INSERT INTO server_error_accounts (email) VALUES (NULL)")
                }
                #expect(error?.sqlState == "23502")
                #expect(error?.columnName == "email")
                #expect(error?.tableName == "server_error_accounts")
            }
        }
    }
}
