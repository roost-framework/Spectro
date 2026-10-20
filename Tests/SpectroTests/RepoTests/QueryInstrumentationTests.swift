import Foundation
import Logging
import PostgresNIO
import Testing
@testable import Spectro

/// Collects values reported from event loop threads.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

private struct RecordingLogHandler: LogHandler {
    let messages: Recorder<String>
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        let fields = (metadata ?? [:]).keys.sorted().joined(separator: ",")
        messages.append("\(level) \(message) [\(fields)]")
    }
}

extension DatabaseIntegrationTests {
@Suite("Query logging and observation", .serialized)
struct QueryInstrumentationTests {
    private func withSpectro(_ body: (Spectro, Recorder<QueryEvent>, Recorder<String>) async throws -> Void) async throws {
        let events = Recorder<QueryEvent>()
        let messages = Recorder<String>()
        let config = DatabaseConfiguration(
            hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
            password: TestDatabase.password, database: TestDatabase.database,
            maxConnectionsPerEventLoop: 1, numberOfThreads: 1,
            logger: Logger(label: "spectro.test") { _ in RecordingLogHandler(messages: messages) },
            onQuery: { events.append($0) }
        )
        let spectro = try Spectro(configuration: config)
        do {
            try await body(spectro, events, messages)
        } catch {
            await spectro.shutdown()
            throw error
        }
        await spectro.shutdown()
    }

    @Test("Pool statements report SQL, parameters, rows, and queue time")
    func poolStatements() async throws {
        try await withSpectro { spectro, events, messages in
            let repo = spectro.repository()
            let rows = try await repo.executeRawQuery(sql: "SELECT generate_series(1, $1) AS n", parameters: [PostgresData(int: 3)])
            #expect(rows.count == 3)

            let event = try #require(events.values.last)
            #expect(event.sql == "SELECT generate_series(1, $1) AS n")
            #expect(event.parameters.first?.int == 3)
            #expect(event.rowCount == 3)
            #expect(event.queueTime != nil)
            #expect(event.inTransaction == false)
            #expect(event.error == nil)
            #expect(messages.values.last == "debug QUERY OK SELECT generate_series(1, $1) AS n [db_ms,params,queue_ms,rows]")
        }
    }

    @Test("Transactions report BEGIN, their statements, and COMMIT or ROLLBACK")
    func transactions() async throws {
        try await withSpectro { spectro, events, _ in
            try await spectro.transaction { tx in
                _ = try await tx.executeRawQuery(sql: "SELECT 1 AS one")
            }
            #expect(events.values.map(\.sql) == ["BEGIN ISOLATION LEVEL READ COMMITTED", "SELECT 1 AS one", "COMMIT"])
            #expect(events.values.allSatisfy { $0.inTransaction && $0.queueTime == nil })

            _ = try? await spectro.transaction { tx in
                _ = try await tx.executeRawQuery(sql: "SELECT missing_column FROM pg_class")
            }
            let failed = events.values.suffix(3)
            #expect(failed.map(\.sql) == ["BEGIN ISOLATION LEVEL READ COMMITTED", "SELECT missing_column FROM pg_class", "ROLLBACK"])
            #expect(failed.dropFirst().first?.error != nil)
        }
    }

    @Test("Failed statements are logged as errors without their bound values")
    func failures() async throws {
        try await withSpectro { spectro, events, messages in
            await #expect(throws: SpectroError.self) {
                try await spectro.repository().executeRawQuery(sql: "SELECT $1::int / 0", parameters: [PostgresData(int: 42)])
            }
            #expect(events.values.last?.error != nil)
            #expect(events.values.last?.rowCount == 0)
            let message = try #require(messages.values.last)
            #expect(message.hasPrefix("debug QUERY ERROR SELECT $1::int / 0"))
            #expect(message.contains("error"))
            #expect(!message.contains("42"))
        }
    }
}
}
