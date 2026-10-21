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

    /// Insert records in batches, skipping or updating those that conflict with existing rows,
    /// like Ecto's `insert_all` with `on_conflict`. Returns the records inserted or updated.
    ///
    /// ```swift
    /// let added = try await repo.insertAll(tags, onConflict: .nothing(on: .columns(["name"])))
    /// let synced = try await repo.insertAll(products, onConflict: .replace(on: .columns(["sku"]), columns: ["price"]))
    /// ```
    ///
    /// One batch must not update the same row twice: PostgreSQL rejects that.
    public func insertAll<T: Schema>(_ instances: [T], onConflict: ConflictAction, includePrimaryKey: Bool = false) async throws -> [T] {
        try await RepoOperations(executor: query(T.self).executor)
            .insertAll(instances, includePrimaryKey: includePrimaryKey, onConflict: onConflict)
    }

    /// Insert a record, skipping or updating it when it conflicts with an existing row.
    /// Returns `nil` when the record was skipped.
    public func insert<T: Schema>(_ instance: T, onConflict: ConflictAction, includePrimaryKey: Bool = false) async throws -> T? {
        try await insertAll([instance], onConflict: onConflict, includePrimaryKey: includePrimaryKey).first
    }

    /// The record as stored now, like Ecto's `Repo.reload`, or `nil` once it is deleted or soft-deleted.
    public func reload<T: Schema>(_ record: T) async throws -> T? {
        try await reload([record])[0]
    }

    /// The records as stored now, in one query and in the same order, with `nil` for those
    /// deleted or soft-deleted since.
    public func reload<T: Schema>(_ records: [T]) async throws -> [T?] {
        guard !records.isEmpty else { return [] }
        let metadata = await SchemaRegistry.shared.register(T.self)
        guard let primaryKey = metadata.fields.first(where: \.isPrimaryKey) else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }
        let keys = try records.map { record in
            guard let key = PreloadQuery<T>.extractPrimaryKeyPair(from: record, fieldName: primaryKey.name) else {
                throw SpectroError.invalidSchema(reason: "Could not extract primary key value from \(T.self)")
            }
            return key
        }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let condition = QueryCondition(
            sql: "\(T.tableName.quoted).\(primaryKey.databaseName.quoted) IN (\(placeholders))",
            parameters: keys.map(\.data)
        )
        var current: [AnyHashable: T] = [:]
        for record in try await query(T.self).where({ _ in condition }).all() {
            if let key = PreloadQuery<T>.extractPrimaryKeyPair(from: record, fieldName: primaryKey.name)?.key {
                current[key] = record
            }
        }
        return keys.map { current[$0.key] }
    }

    public func executeRawQuery(sql: String) async throws -> [PostgresRow] {
        try await executeRawQuery(sql: sql, parameters: [])
    }

    /// Run a statement written as an `SQLFragment`, like Ecto's `Repo.query`. Interpolated
    /// values are bound parameters, numbered in order, and a literal `?` stays in the SQL.
    ///
    /// ```swift
    /// let rows = try await repo.executeRawQuery(
    ///     "SELECT \(identifier: "id"), \(score) FROM \(identifier: "posts") WHERE \(identifier: "id") = ANY(\(ids))"
    /// )
    /// ```
    public func executeRawQuery(_ statement: SQLFragment) async throws -> [PostgresRow] {
        try await executeRawQuery(sql: renumberPlaceholders(in: statement.sql), parameters: statement.parameters)
    }

    /// Clear a soft-deleted record's deletion timestamp and return the record.
    ///
    /// Restoring a record that is not deleted returns it unchanged.
    /// - Throws: `SpectroError.notFound` for an unknown id, and `SpectroError.invalidSchema`
    ///   for a schema without a primary key or soft-delete column.
    public func restore<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(schema)

        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }
        guard let sdf = metadata.softDeleteField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no soft-delete column to restore")
        }

        let sql = """
            UPDATE \(metadata.tableName.quoted)
            SET \(sdf.quoted) = NULL
            WHERE \(primaryKey.snakeCase().quoted) = $1
            RETURNING *
            """
        guard let row = try await executeRawQuery(sql: sql, parameters: [id.toPostgresData()]).first else {
            throw SpectroError.notFound(schema: metadata.tableName, id: String(describing: id))
        }
        return try await T.from(row: row)
    }

    // MARK: - Preloading Loaded Records

    /// Load a has-many or many-to-many relationship for records already fetched, in one
    /// query for all of them, like Ecto's `Repo.preload`. `customize` adjusts the query that
    /// loads the related records; see `PreloadQuery`.
    public func preload<T: Schema, Related: Schema>(
        _ records: [T],
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) async throws -> [T] {
        guard !records.isEmpty else { return records }
        return try await PreloadQuery<T>.preloader(keyPath, foreignKey: foreignKey, customize)(records, self)
    }

    /// Load a has-one or belongs-to relationship for records already fetched, in one query
    /// for all of them.
    public func preload<T: Schema, Related: Schema>(
        _ records: [T],
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) async throws -> [T] {
        guard !records.isEmpty else { return records }
        return try await PreloadQuery<T>.preloader(keyPath, foreignKey: foreignKey, customize)(records, self)
    }

    /// Load a has-many or many-to-many relationship for one record.
    public func preload<T: Schema, Related: Schema>(
        _ record: T,
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) async throws -> T {
        try await preload([record], keyPath, foreignKey: foreignKey, customize)[0]
    }

    /// Load a has-one or belongs-to relationship for one record.
    public func preload<T: Schema, Related: Schema>(
        _ record: T,
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) async throws -> T {
        try await preload([record], keyPath, foreignKey: foreignKey, customize)[0]
    }
}
