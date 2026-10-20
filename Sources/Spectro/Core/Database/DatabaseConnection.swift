// @preconcurrency suppresses Sendable warnings originating in NIO/PostgresKit types
// that predate Swift 6. Remove when those packages gain full Sendable annotations.
@preconcurrency import NIOCore
@preconcurrency import PostgresKit
import Foundation
import Logging
import NIOSSL

public actor DatabaseConnection {
    // nonisolated(unsafe) lets us call pools.shutdown() — which is marked
    // @available(*, noasync) — from within the async shutdown() method without
    // hitting the "calls wait()" diagnostic. Both are `let` constants so there
    // is no concurrent mutation to guard against.
    private nonisolated(unsafe) let pools: EventLoopGroupConnectionPool<PostgresConnectionSource>
    private nonisolated let eventLoopGroup: any EventLoopGroup
    private let configuration: DatabaseConfiguration
    private nonisolated let instrumentation: QueryInstrumentation
    private var isShutdown = false

    /// Tracks the number of in-flight query operations. shutdown() waits for
    /// this to reach zero before tearing down the pool, preventing SIGBUS
    /// crashes caused by NIO future callbacks accessing a freed pool.
    private var activeOperations = 0
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var sandboxSavepoints = 0
    /// Open sandboxes, each with the tasks waiting for its connection. A key is present
    /// while one of its tasks uses the connection for a transaction.
    private var openSandboxes: Set<UUID> = []
    private var sandboxWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(configuration: DatabaseConfiguration) throws {
        self.configuration = configuration
        self.instrumentation = QueryInstrumentation(logger: configuration.logger, observer: configuration.onQuery)
        let sqlConfig = SQLPostgresConfiguration(
            hostname: configuration.hostname,
            port: configuration.port,
            username: configuration.username,
            password: configuration.password,
            database: configuration.database,
            tls: try configuration.tlsConfiguration.map { .require(try NIOSSLContext(configuration: $0)) } ?? .disable
        )

        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: configuration.numberOfThreads)
        let source = PostgresConnectionSource(sqlConfiguration: sqlConfig)

        self.pools = EventLoopGroupConnectionPool(
            source: source,
            maxConnectionsPerEventLoop: configuration.maxConnectionsPerEventLoop,
            on: eventLoopGroup
        )
    }

    // MARK: - Operation Tracking

    private func beginOperation() throws {
        guard !isShutdown else {
            throw SpectroError.connectionFailed(underlying: DatabaseConnectionError.connectionClosed)
        }
        activeOperations += 1
    }

    private func endOperation() {
        activeOperations -= 1
        if activeOperations == 0, let continuation = shutdownContinuation {
            shutdownContinuation = nil
            continuation.resume()
        }
    }

    // MARK: - Query Execution

    public func executeQuery<T: Sendable>(
        sql: String,
        parameters: [PostgresData] = [],
        resultMapper: @Sendable @escaping (PostgresRow) throws -> T
    ) async throws -> [T] {
        if let sandbox = try sandboxBinding() {
            return try await withSandboxConnection(sandbox) {
                try await sandbox.context.query(sql, parameters, mapper: resultMapper)
            }
        }
        try beginOperation()
        defer { endOperation() }

        let instrumentation = self.instrumentation
        let requested = ContinuousClock.now
        return try await withCheckedThrowingContinuation { continuation in
            let future: EventLoopFuture<[PostgresRow]> = self.pools.withConnection { connection in
                let started = ContinuousClock.now
                return instrumentation.observe(
                    connection.query(sql, parameters).map(\.rows),
                    sql: sql, parameters: parameters, queued: requested.duration(to: started),
                    started: started, inTransaction: false, rowCount: \.count
                )
            }
            future.whenComplete { result in
                switch result {
                case .success(let rows):
                    do { continuation.resume(returning: try rows.map(resultMapper)) }
                    catch { continuation.resume(throwing: SpectroError.queryExecutionFailed(sql: sql, error: error)) }
                case .failure(let error): continuation.resume(throwing: SpectroError.queryExecutionFailed(sql: sql, error: error))
                }
            }
        }
    }

    public func executeUpdate(sql: String, parameters: [PostgresData] = []) async throws {
        _ = try await executeQuery(sql: sql, parameters: parameters) { _ in () }
    }

    public func execute(sql: String, parameters: [PostgresData] = []) async throws -> Int {
        try await executeUpdate(sql: sql, parameters: parameters)
        return 1
    }

    // MARK: - Transactions

    /// Reserve one physical session for a migration command. Session locks must
    /// span multiple transactions. Always retire this connection before releasing
    /// the pool slot, so locks and failed transactions cannot leak to another caller.
    internal func withMigrationSession<T: Sendable>(
        _ work: @Sendable (TransactionContext) async throws -> T
    ) async throws -> T {
        try beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        let connection = try await requestConnection()
        defer { pools.releaseConnection(connection) }
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await work(TransactionContext(connection: connection, instrumentation: instrumentation))
                try Task.checkCancellation()
                return result
            } onCancel: {
                // Closing an owned session interrupts SQL and releases server locks.
                // The handler is removed before this connection is returned to the pool.
                let _: EventLoopFuture<Void> = connection.close()
            }
            try await connection.close()
            return result
        } catch {
            try? await connection.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Reserve a pooled connection outside `withConnection`, honoring cancellation.
    private func requestConnection() async throws -> PostgresConnection {
        let request = MigrationConnectionRequest()
        // AsyncKit cannot remove a queued request. Track it until completion, even
        // if the caller has already cancelled; a late connection is released unused.
        try beginOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                pools.requestConnection().whenComplete { result in
                    if !request.complete(result), case .success(let connection) = result {
                        self.pools.releaseConnection(connection)
                    }
                    Task { await self.endOperation() }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    public func transaction<T: Sendable>(
        _ work: @escaping @Sendable (TransactionContext) async throws -> T
    ) async throws -> T {
        if let sandbox = try sandboxBinding() {
            return try await withSandboxConnection(sandbox) {
                try await self.sandboxSavepoint(sandbox.context, work)
            }
        }
        try beginOperation()

        do {
            let instrumentation = self.instrumentation
            let result: T = try await withCheckedThrowingContinuation { continuation in
                let future: EventLoopFuture<T> = self.pools.withConnection { connection in
                    let context = TransactionContext(connection: connection, instrumentation: instrumentation)
                    return context.run("BEGIN ISOLATION LEVEL READ COMMITTED").flatMap { _ in
                        connection.eventLoop.makeFutureWithTask {
                            try await work(context)
                        }
                        .flatMap { result in
                            context.run("COMMIT").map { _ in result }
                        }
                        .flatMapError { error in
                            context.run("ROLLBACK").flatMapErrorThrowing { rollbackError in
                                throw SpectroError.transactionAndRollbackFailed(
                                    original: error,
                                    rollback: rollbackError
                                )
                            }.flatMapThrowing { _ in
                                throw SpectroError.transactionFailed(underlying: error)
                            }
                        }
                    }
                }

                future.whenComplete { result in
                    continuation.resume(with: result)
                }
            }
            endOperation()
            return result
        } catch {
            endOperation()
            throw error
        }
    }

    // MARK: - Sandbox

    /// The sandbox transaction of the current task, if it belongs to this connection pool.
    @TaskLocal private static var sandbox: SandboxBinding?
    /// The sandbox whose connection the current task holds for a transaction.
    @TaskLocal private static var heldSandbox: UUID?

    private struct SandboxBinding: Sendable {
        let id: UUID
        let owner: ObjectIdentifier
        let context: TransactionContext
    }

    /// The current task's sandbox on this pool. Throws once the sandbox has ended, for a
    /// task such as `Task { }` that inherited it: its statements must not reach the pool.
    private func sandboxBinding() throws -> SandboxBinding? {
        guard let binding = Self.sandbox, binding.owner == ObjectIdentifier(self) else { return nil }
        guard openSandboxes.contains(binding.id) else {
            throw SpectroError.invalidQuery("A statement ran after the sandbox it inherited ended. Await tasks started in a sandbox before it returns.")
        }
        return binding
    }

    /// Run `body` in a transaction that is always rolled back, like Ecto's SQL sandbox.
    ///
    /// Statements this pool runs from `body` and from tasks that inherit its task-local
    /// values, such as child tasks and `Task { }`, use that transaction, so data written there
    /// is visible to them and is discarded afterwards. `transaction` becomes a savepoint, and
    /// holds the connection until it ends, so other tasks' statements wait for it.
    /// `Task.detached` uses the pool as usual. Statements after the sandbox ends throw.
    public func sandbox<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if try sandboxBinding() != nil { return try await body() }
        try beginOperation()
        defer { endOperation() }
        let connection = try await requestConnection()
        defer { pools.releaseConnection(connection) }

        let binding = SandboxBinding(
            id: UUID(),
            owner: ObjectIdentifier(self),
            context: TransactionContext(connection: connection, instrumentation: instrumentation)
        )
        openSandboxes.insert(binding.id)
        let result: Result<T, any Error>
        do {
            try await binding.context.execute("BEGIN")
            result = .success(try await Self.$sandbox.withValue(binding) { try await body() })
        } catch {
            result = .failure(error)
        }
        // Statements already sent precede the rollback on the connection; later ones throw.
        openSandboxes.remove(binding.id)
        do {
            // A task that outlived the body still holds the connection, and its transaction
            // would continue after a rollback. Closing aborts it; the server rolls back.
            guard sandboxWaiters[binding.id] == nil else {
                try? await connection.close()
                return try result.get()
            }
            try await binding.context.execute("ROLLBACK")
        } catch {
            // Never return a connection with an open transaction to the pool.
            try? await connection.close()
            if case .success = result { throw error }
        }
        return try result.get()
    }

    /// Run `work` once no other task of the sandbox holds its connection for a transaction.
    private func withSandboxConnection<T: Sendable>(
        _ sandbox: SandboxBinding,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        if Self.heldSandbox == sandbox.id { return try await work() }
        if sandboxWaiters[sandbox.id] != nil {
            await withCheckedContinuation { sandboxWaiters[sandbox.id, default: []].append($0) }
        } else {
            sandboxWaiters[sandbox.id] = []
        }
        defer {
            if let next = sandboxWaiters[sandbox.id]?.first {
                sandboxWaiters[sandbox.id]?.removeFirst()
                next.resume()
            } else {
                sandboxWaiters[sandbox.id] = nil
            }
        }
        _ = try sandboxBinding()
        return try await Self.$heldSandbox.withValue(sandbox.id) { try await work() }
    }

    /// A transaction inside a sandbox: a savepoint, with the errors `transaction` throws.
    private func sandboxSavepoint<T: Sendable>(
        _ context: TransactionContext,
        _ work: @escaping @Sendable (TransactionContext) async throws -> T
    ) async throws -> T {
        sandboxSavepoints += 1
        let name = "spectro_sandbox_\(sandboxSavepoints)".quoted
        try await context.execute("SAVEPOINT \(name)")
        do {
            let result = try await work(context)
            try await context.execute("RELEASE SAVEPOINT \(name)")
            return result
        } catch {
            do {
                try await context.execute("ROLLBACK TO SAVEPOINT \(name)")
            } catch let rollbackError {
                throw SpectroError.transactionAndRollbackFailed(original: error, rollback: rollbackError)
            }
            throw SpectroError.transactionFailed(underlying: error)
        }
    }

    // MARK: - Lifecycle

    public nonisolated var config: DatabaseConfiguration { configuration }

    /// Gracefully shuts down the database connection pool.
    ///
    /// Waits for all in-flight operations to complete before tearing down the
    /// pool, preventing SIGBUS crashes from NIO future callbacks referencing
    /// freed pool memory.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true

        if activeOperations > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.shutdownContinuation = continuation
            }
        }

        syncShutdownPools()
        do {
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            // Best-effort; don't propagate
        }
    }

    private nonisolated func syncShutdownPools() {
        pools.shutdown()
    }

    // Best-effort sync teardown in deinit to prevent NIO SIGBUS when tests drop
    // a DatabaseConnection without calling shutdown(). Both pools.shutdown() and
    // syncShutdownGracefully() are idempotent, so double-shutdown is safe.
    // We cannot read isShutdown here (actor-isolated), so we always call —
    // the NIO internals guard against double-shutdown themselves.
    nonisolated public func syncShutdown() {
        pools.shutdown()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    // MARK: - Health Check

    public func testConnection() async throws -> String {
        let result = try await executeQuery(
            sql: "SELECT version() as version",
            resultMapper: { row in
                let randomAccess = row.makeRandomAccess()
                guard let version = randomAccess[data: "version"].string else {
                    throw SpectroError.resultDecodingFailed(column: "version", expectedType: "String")
                }
                return version
            }
        )
        guard let version = result.first else {
            throw SpectroError.unexpectedResultCount(expected: 1, actual: 0)
        }
        return version
    }
}

// MARK: - DatabaseConfiguration

/// Connection credentials, pool sizing, and optional TLS settings for PostgreSQL.
///
/// Pass a value to ``Spectro/Spectro/init(configuration:)`` or a database connection.
/// See <doc:TransactionsAndConfiguration> for environment loading and lifecycle.
public struct DatabaseConfiguration: Sendable {
    public let hostname: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let maxConnectionsPerEventLoop: Int
    public let numberOfThreads: Int
    public let tlsConfiguration: TLSConfiguration?
    /// Receives a debug message for each statement, with its SQL and timings but not its
    /// bound values. `nil`, the default, logs nothing.
    public let logger: Logger?
    /// Receives a `QueryEvent` for each statement, for metrics or tracing.
    public let onQuery: QueryObserver?

    public init(
        hostname: String = "localhost",
        port: Int = 5432,
        username: String,
        password: String,
        database: String,
        maxConnectionsPerEventLoop: Int = 4,
        numberOfThreads: Int = System.coreCount,
        tlsConfiguration: TLSConfiguration? = nil,
        logger: Logger? = nil,
        onQuery: QueryObserver? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.maxConnectionsPerEventLoop = maxConnectionsPerEventLoop
        self.numberOfThreads = numberOfThreads
        self.tlsConfiguration = tlsConfiguration
        self.logger = logger
        self.onQuery = onQuery
    }

    public static func fromEnvironment() throws -> DatabaseConfiguration {
        guard let username = ProcessInfo.processInfo.environment["DB_USER"] else {
            throw SpectroError.missingEnvironmentVariable("DB_USER")
        }
        guard let password = ProcessInfo.processInfo.environment["DB_PASSWORD"] else {
            throw SpectroError.missingEnvironmentVariable("DB_PASSWORD")
        }
        guard let database = ProcessInfo.processInfo.environment["DB_NAME"] else {
            throw SpectroError.missingEnvironmentVariable("DB_NAME")
        }
        let hostname = ProcessInfo.processInfo.environment["DB_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["DB_PORT"] ?? "5432") ?? 5432
        return DatabaseConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database
        )
    }
}

// MARK: - TransactionContext
//
// `TransactionContext` is marked `@unchecked Sendable` with the following safety contract:
//
// 1. The wrapped `PostgresConnection` is pinned to a single NIO EventLoop for
//    the entire lifetime of the transaction.
// 2. `TransactionContext` instances are created inside `transaction()` and are
//    only valid within the transaction closure scope.
// 3. All operations on the connection are serialized by the EventLoop.
// 4. The context MUST NOT be stored or used after the transaction closure returns.
//
// This is safe because NIO's EventLoop guarantees single-threaded execution for
// all operations scheduled on it. The `@unchecked Sendable` allows passing the
// context to async closures that may resume on different threads, but all actual
// database operations are dispatched back to the connection's EventLoop.
//
// Remove this workaround when PostgresNIO adds native Sendable conformance.

public struct TransactionContext: @unchecked Sendable {
    let connection: PostgresConnection
    let instrumentation: QueryInstrumentation

    init(connection: PostgresConnection, instrumentation: QueryInstrumentation) {
        self.connection = connection
        self.instrumentation = instrumentation
    }

    /// Send one statement on the pinned connection and report it.
    func run(_ sql: String, _ parameters: [PostgresData] = []) -> EventLoopFuture<[PostgresRow]> {
        instrumentation.observe(
            connection.query(sql, parameters).map(\.rows),
            sql: sql, parameters: parameters, queued: nil, started: .now, inTransaction: true, rowCount: \.count
        )
    }

    public func query<T: Sendable>(
        _ sql: String,
        _ parameters: [PostgresData] = [],
        mapper: @Sendable @escaping (PostgresRow) throws -> T
    ) async throws -> [T] {
        do {
            return try await run(sql, parameters).get().map(mapper)
        } catch {
            throw SpectroError.queryExecutionFailed(sql: sql, error: error)
        }
    }

    public func execute(_ sql: String, _ parameters: [PostgresData] = []) async throws {
        _ = try await query(sql, parameters) { _ in () }
    }
}

// MARK: - Internal

private enum DatabaseConnectionError: Error {
    case connectionClosed
    case invalidConfiguration
}

/// Synchronizes cancellation with a non-cancellable NIO pool request. The lock
/// protects only continuation ownership; callbacks always resume outside the lock.
private final class MigrationConnectionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PostgresConnection, any Error>?
    private var cancelled = false
    private var completed = false

    func install(_ continuation: CheckedContinuation<PostgresConnection, any Error>) {
        let cancelled = lock.withLock {
            if self.cancelled { return true }
            self.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func complete(_ result: Result<PostgresConnection, any Error>) -> Bool {
        let continuation = lock.withLock {
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    func cancel() {
        let continuation = lock.withLock {
            guard !completed else { return nil as CheckedContinuation<PostgresConnection, any Error>? }
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
