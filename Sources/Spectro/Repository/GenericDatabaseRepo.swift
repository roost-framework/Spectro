import Foundation
import PostgresNIO

/// Generic database repository that works with any Schema type.
///
/// `GenericDatabaseRepo` provides a type-safe, actor-based data access layer for PostgreSQL.
/// It implements the Repository pattern with full CRUD operations, query building, and transaction support.
public actor GenericDatabaseRepo: Repo {
    private let connection: DatabaseConnection
    private let operations: RepoOperations

    public init(connection: DatabaseConnection) {
        self.connection = connection
        self.operations = RepoOperations(executor: connection)
    }

    // MARK: - Query

    public nonisolated func query<T: Schema>(_ schema: T.Type) -> Query<T> {
        Query(schema: schema, executor: connection)
    }

    // MARK: - Raw SQL

    public func executeRawSQL(_ sql: String) async throws {
        _ = try await operations.rows(sql)
    }

    /// Execute a raw SQL query with parameters and return raw PostgresRow results.
    /// Useful for junction table queries in many-to-many preloading.
    public func executeRawQuery(
        sql: String,
        parameters: [PostgresData] = []
    ) async throws -> [PostgresRow] {
        try await operations.rows(sql, parameters)
    }

    // MARK: - CRUD

    public func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T? {
        try await operations.get(schema, id: id)
    }

    public func all<T: Schema>(_ schema: T.Type) async throws -> [T] {
        try await operations.all(schema)
    }

    public func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool = false) async throws -> T {
        try await operations.insert(instance, includePrimaryKey: includePrimaryKey)
    }

    public func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]?, includePrimaryKey: Bool = false) async throws -> T {
        try await operations.upsert(instance, conflictTarget: conflictTarget, set: set, includePrimaryKey: includePrimaryKey)
    }

    public func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool = false) async throws -> [T] {
        try await operations.insertAll(instances, includePrimaryKey: includePrimaryKey)
    }

    public func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, changes: [String: any Sendable]) async throws -> T {
        try await operations.update(schema, id: id, changes: changes)
    }

    public func getOrFail<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T {
        try await operations.getOrFail(schema, id: id)
    }

    public func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws {
        try await operations.delete(schema, id: id)
    }

    public func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T {
        try await transaction(isolation: .readCommitted, work)
    }

    /// Run `work` in a transaction with the given isolation level.
    ///
    /// ```swift
    /// let balance = try await repo.transaction(isolation: .serializable) { tx in
    ///     // read, check, and write as if no other transaction ran meanwhile
    /// }
    /// ```
    ///
    /// Under `repeatableRead` and `serializable`, PostgreSQL may abort the transaction with
    /// SQLSTATE `40001`, read from `SpectroError.serverError`; run it again.
    public func transaction<T: Sendable>(
        isolation: TransactionIsolation,
        _ work: @escaping @Sendable (any Repo) async throws -> T
    ) async throws -> T {
        try await connection.transaction(isolation: isolation) { context in
            try await work(TransactionRepo(context: context))
        }
    }

    // MARK: - Changeset Integration

    /// Insert a new record from a validated changeset.
    ///
    /// Builds the INSERT statement directly from the changeset's changes dict,
    /// so it works correctly regardless of whether `T` conforms to `MutableSchema`.
    ///
    /// ```swift
    /// let cs = Changeset.cast(nil, params: ["name": "Alice"], permitted: ["name"])
    ///     .validateRequired(["name"])
    /// let user = try await repo.insert(cs)
    /// ```
    public func insert<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        // Preparations and associations write in one transaction with the record. An invalid
        // changeset throws its validation error without one.
        guard changeset.needsTransaction, changeset.isValid else { return try await operations.insert(changeset) }
        return try await unwrapped { try await self.transaction { tx in try await tx.insert(changeset) } }
    }

    /// Update an existing record from a validated changeset.
    ///
    /// The changeset must have `data != nil` (update mode) and be valid.
    /// Only the changed fields are sent to the database.
    ///
    /// ```swift
    /// let cs = Changeset.cast(existingUser, params: ["name": "Bob"], permitted: ["name"])
    ///     .validateRequired(["name"])
    /// let updated = try await repo.update(cs)
    /// ```
    public func update<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        guard changeset.needsTransaction, changeset.isValid else { return try await operations.update(changeset) }
        return try await unwrapped { try await self.transaction { tx in try await tx.update(changeset) } }
    }

    /// Throw the error of a transaction this repository opened itself as the write's own error,
    /// such as `staleRecord`, as without the transaction.
    private func unwrapped<T: Sendable>(_ write: () async throws -> T) async throws -> T {
        do {
            return try await write()
        } catch SpectroError.transactionFailed(let underlying) {
            throw underlying
        }
    }
}
