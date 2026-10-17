import Foundation
@preconcurrency import PostgresNIO

/// Core repository protocol for database operations
public protocol Repo: Sendable {
    func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T?
    func getOrFail<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T
    func all<T: Schema>(_ schema: T.Type) async throws -> [T]
    func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool) async throws -> T
    func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]?, includePrimaryKey: Bool) async throws -> T
    func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool) async throws -> [T]
    func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, changes: [String: any Sendable]) async throws -> T
    func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws
    func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T
    func query<T: Schema>(_ schema: T.Type) -> Query<T>
    func executeRawSQL(_ sql: String) async throws
    func executeRawQuery(sql: String, parameters: [PostgresData]) async throws -> [PostgresRow]
    func insert<T: Schema>(_ changeset: Changeset<T>) async throws -> T
    func update<T: Schema>(_ changeset: Changeset<T>) async throws -> T
}

extension Repo {
    /// Fetch a record by primary key. When `withDeleted` is true, soft-deleted records are
    /// returned too, as with `Query.withDeleted()`.
    public func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, withDeleted: Bool) async throws -> T? {
        guard withDeleted else { return try await get(schema, id: id) }

        let metadata = await SchemaRegistry.shared.register(schema)
        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        let condition = QueryCondition(
            sql: "\(primaryKey.snakeCase().quoted) = ?",
            parameters: [id.toPostgresData()]
        )
        return try await query(schema).withDeleted().where { _ in condition }.first()
    }

    public func insert<T: Schema>(_ instance: T) async throws -> T {
        try await insert(instance, includePrimaryKey: false)
    }

    public func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]? = nil) async throws -> T {
        try await upsert(instance, conflictTarget: conflictTarget, set: set, includePrimaryKey: false)
    }

    public func insertAll<T: Schema>(_ instances: [T]) async throws -> [T] {
        try await insertAll(instances, includePrimaryKey: false)
    }

    public func executeRawQuery(sql: String) async throws -> [PostgresRow] {
        try await executeRawQuery(sql: sql, parameters: [])
    }

}
