import Foundation
import PostgresNIO

/// A repository backed by a pinned `TransactionContext` connection.
///
/// All CRUD operations execute on the same database connection that issued `BEGIN`,
/// guaranteeing atomicity. Created automatically by `GenericDatabaseRepo.transaction()`.
///
/// `query()` builds queries on the same connection, so they run inside the transaction too.
///
/// Nested transactions are not supported and throw `SpectroError.transactionAlreadyStarted`.
/// Use `savepoint(_:)` to roll back part of a transaction without aborting the rest.
public actor TransactionRepo: Repo {
    private let context: TransactionContext
    private let operations: RepoOperations
    private var savepointCount = 0

    init(context: TransactionContext) {
        self.context = context
        self.operations = RepoOperations(executor: context)
    }

    // MARK: - Query

    public nonisolated func query<T: Schema>(_ schema: T.Type) -> Query<T> {
        Query(schema: schema, executor: context)
    }

    // MARK: - Raw SQL

    public func executeRawSQL(_ sql: String) async throws {
        try await context.execute(sql)
    }

    public func executeRawQuery(
        sql: String,
        parameters: [PostgresData] = []
    ) async throws -> [PostgresRow] {
        try await context.query(sql, parameters, mapper: { $0 })
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

    public func insert<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        guard changeset.needsTransaction, changeset.isValid else { return try await operations.insert(changeset) }
        // A savepoint keeps the writes atomic when the caller catches an error and commits.
        return try await savepoint { tx in
            let changeset = try await changeset.prepared(using: tx)
            return try await changeset.writeAssociations(of: self.operations.insert(changeset), using: tx)
        }
    }

    public func update<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        guard changeset.needsTransaction, changeset.isValid else { return try await operations.update(changeset) }
        return try await savepoint { tx in
            let changeset = try await changeset.prepared(using: tx)
            return try await changeset.writeAssociations(of: self.operations.update(changeset), using: tx)
        }
    }

    public func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T {
        throw SpectroError.transactionAlreadyStarted
    }

    // MARK: - Savepoints

    /// Run `body` inside a savepoint of this transaction.
    ///
    /// The savepoint is released when `body` returns. When `body` throws, its changes are rolled
    /// back to the savepoint, the transaction stays usable, and the error is rethrown unchanged.
    /// Savepoints can nest.
    /// - Throws: The error `body` threw, or `SpectroError.transactionAndRollbackFailed` if the
    ///   rollback to the savepoint fails.
    public func savepoint<T: Sendable>(_ body: @escaping @Sendable (TransactionRepo) async throws -> T) async throws -> T {
        savepointCount += 1
        let name = "spectro_sp_\(savepointCount)".quoted
        try await context.execute("SAVEPOINT \(name)")

        let result: T
        do {
            result = try await body(self)
        } catch {
            do {
                try await context.execute("ROLLBACK TO SAVEPOINT \(name)")
                try await context.execute("RELEASE SAVEPOINT \(name)")
            } catch let rollbackError {
                throw SpectroError.transactionAndRollbackFailed(original: error, rollback: rollbackError)
            }
            throw error
        }

        try await context.execute("RELEASE SAVEPOINT \(name)")
        return result
    }
}
