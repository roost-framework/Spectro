import Foundation
@preconcurrency import PostgresKit

/// Typealias to disambiguate Spectro type from Spectro module.
/// Use `SpectroClient` when `import Spectro` causes ambiguity.
public typealias SpectroClient = Spectro

/// Swift ORM for PostgreSQL with property wrapper schemas and actor-based concurrency.
public struct Spectro: Sendable {
    private let connection: DatabaseConnection

    public init(configuration: DatabaseConfiguration) throws {
        self.connection = try DatabaseConnection(configuration: configuration)
    }

    public init(
        hostname: String = "localhost",
        port: Int = 5432,
        username: String,
        password: String,
        database: String,
        maxConnectionsPerEventLoop: Int = 4
    ) throws {
        let config = DatabaseConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            maxConnectionsPerEventLoop: maxConnectionsPerEventLoop
        )
        try self.init(configuration: config)
    }

    public static func fromEnvironment() throws -> Spectro {
        try Spectro(configuration: DatabaseConfiguration.fromEnvironment())
    }

    public func repository() -> GenericDatabaseRepo {
        GenericDatabaseRepo(connection: connection)
    }

    public func testConnection() async throws -> String {
        try await connection.testConnection()
    }

    public func migrationManager(migrationsPath: URL? = nil, lockTimeout: Duration = .seconds(30)) -> MigrationManager {
        MigrationManager(connection: connection, migrationsPath: migrationsPath, lockTimeout: lockTimeout)
    }

    public func shutdown() async {
        await connection.shutdown()
    }

    /// Run `body` in a transaction that is always rolled back, for tests, like Ecto's SQL sandbox.
    ///
    /// Every repository made from this instance, in `body` and the tasks that inherit its
    /// task-local values, runs its statements in that transaction, so code under test needs no
    /// changes. `transaction` becomes a savepoint that holds the connection until it ends.
    /// Data written in `body` is discarded when it returns or throws, and statements from a
    /// task that outlives it throw.
    ///
    /// ```swift
    /// @Test func signup() async throws {
    ///     try await spectro.sandbox { repo in
    ///         try await SignupService(repo: spectro.repository()).register(email: "a@b.c")
    ///         #expect(try await repo.query(User.self).count() == 1)
    ///     }
    /// }
    /// ```
    public func sandbox<T: Sendable>(_ body: @Sendable (GenericDatabaseRepo) async throws -> T) async throws -> T {
        let repo = repository()
        return try await connection.sandbox { try await body(repo) }
    }
}

// MARK: - Convenience

extension Spectro {
    public func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T {
        try await repository().transaction(work)
    }

    public func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T? {
        try await repository().get(schema, id: id)
    }

    public func all<T: Schema>(_ schema: T.Type) async throws -> [T] {
        try await repository().all(schema)
    }

    public func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool = false) async throws -> T {
        try await repository().insert(instance, includePrimaryKey: includePrimaryKey)
    }

    public func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]? = nil, includePrimaryKey: Bool = false) async throws -> T {
        try await repository().upsert(instance, conflictTarget: conflictTarget, set: set, includePrimaryKey: includePrimaryKey)
    }

    public func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool = false) async throws -> [T] {
        try await repository().insertAll(instances, includePrimaryKey: includePrimaryKey)
    }

    public func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, changes: [String: any Sendable]) async throws -> T {
        try await repository().update(schema, id: id, changes: changes)
    }

    public func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws {
        try await repository().delete(schema, id: id)
    }
}
