import Foundation
import PostgresNIO

// MARK: - Row Locks

/// Which row lock `Query.lock(_:_:)` takes.
public enum RowLockStrength: Sendable {
    /// `FOR UPDATE`: blocks all other locks and writes.
    case update
    /// `FOR NO KEY UPDATE`: like `update`, but allows inserts referencing the rows.
    case noKeyUpdate
    /// `FOR SHARE`: blocks writes, allows other share locks.
    case share
    /// `FOR KEY SHARE`: blocks deletes and key changes only.
    case keyShare

    var sql: String {
        switch self {
        case .update: "UPDATE"
        case .noKeyUpdate: "NO KEY UPDATE"
        case .share: "SHARE"
        case .keyShare: "KEY SHARE"
        }
    }
}

/// What `Query.lock(_:_:)` does when another transaction holds a conflicting lock.
public enum RowLockWait: Sendable {
    /// Wait for the other transaction.
    case wait
    /// Fail immediately with SQLSTATE 55P03.
    case noWait
    /// Leave locked rows out of the result, as job queues do.
    case skipLocked

    var sql: String {
        switch self {
        case .wait: ""
        case .noWait: " NOWAIT"
        case .skipLocked: " SKIP LOCKED"
        }
    }
}

// MARK: - Bulk Writes

/// One `SET` item of `Query.updateAll(_:)`, like Ecto's `set:`, `inc:`, `push:`, and `pull:`.
public struct FieldAssignment: Sendable {
    let column: String
    let sql: String
    let parameters: [PostgresData]
}

extension QueryField {
    /// Set the column to `value`.
    public func set(_ value: V) -> FieldAssignment where V: DatabaseValue {
        FieldAssignment(column: name, sql: "?", parameters: [convertToPostgresData(value)])
    }

    /// Set the column to a SQL expression, such as `"\($0.title) || \(suffix)"` or `"now()"`.
    /// The label keeps a string value from being read as SQL.
    public func set(sql expression: SQLFragment) -> FieldAssignment {
        FieldAssignment(column: name, sql: expression.sql, parameters: expression.parameters)
    }

    /// Append `element` to the array column.
    public func push<E: DatabaseValue>(_ element: E) -> FieldAssignment where V == [E] {
        FieldAssignment(column: name, sql: "array_append(\(qualifiedName), ?)", parameters: [convertToPostgresData(element)])
    }

    /// Remove every occurrence of `element` from the array column.
    public func pull<E: DatabaseValue>(_ element: E) -> FieldAssignment where V == [E] {
        FieldAssignment(column: name, sql: "array_remove(\(qualifiedName), ?)", parameters: [convertToPostgresData(element)])
    }
}

extension QueryField where V: Numeric & DatabaseValue {
    /// Add `amount` to the column; a negative amount subtracts.
    public func increment(by amount: V) -> FieldAssignment {
        FieldAssignment(column: name, sql: "\(qualifiedName) + ?", parameters: [convertToPostgresData(amount)])
    }
}

extension Query {
    /// Update every row the query matches and return how many were updated, like Ecto's `update_all`.
    ///
    /// ```swift
    /// let count = try await repo.query(Post.self)
    ///     .where { $0.authorId == authorID }
    ///     .updateAll { [$0.views.increment(by: 1), $0.tags.push("featured")] }
    /// ```
    ///
    /// Soft-deleted rows are left unchanged unless the query uses `withDeleted()`. Joins,
    /// ordering, limits, and offsets select the rows to update. Row locks and grouping are ignored.
    @discardableResult
    public func updateAll(_ assignments: (QueryBuilder<T>) -> [FieldAssignment]) async throws -> Int {
        let assignments = assignments(QueryBuilder<T>())
        guard !assignments.isEmpty else {
            throw SpectroError.invalidQuery("updateAll requires at least one assignment")
        }
        let set = assignments.map { "\($0.column.quoted) = \($0.sql)" }.joined(separator: ", ")
        let (filter, filterParameters) = try await writeFilter()
        return try await countAffected(
            "UPDATE \(T.tableName.quoted) SET \(set)\(filter)",
            assignments.flatMap(\.parameters) + filterParameters
        )
    }

    /// Delete every row the query matches and return how many were deleted, like Ecto's `delete_all`.
    ///
    /// For a schema with `@SoftDelete`, rows that are not already deleted get their deletion
    /// time set instead, as `Repo.delete` does, even with `withDeleted()`.
    @discardableResult
    public func deleteAll() async throws -> Int {
        let (filter, filterParameters) = try await writeFilter()
        guard let softDelete = T.softDeleteColumn else {
            return try await countAffected("DELETE FROM \(T.tableName.quoted)\(filter)", filterParameters)
        }
        let column = softDelete.quoted
        let notDeleted = "\(T.tableName.quoted).\(column) IS NULL"
        let condition = filter.isEmpty ? " WHERE \(notDeleted)" : "\(filter) AND \(notDeleted)"
        return try await countAffected("UPDATE \(T.tableName.quoted) SET \(column) = NOW()\(condition)", filterParameters)
    }

    /// The WHERE clause selecting the rows to write, with `?` placeholders.
    /// Joins and row windows need a primary key subquery; plain filters apply directly.
    private func writeFilter() async throws -> (sql: String, parameters: [PostgresData]) {
        try validateJoins()
        if joins.isEmpty && limitValue == nil && offsetValue == nil {
            let filter = buildWhereClause()
            return (filter.isEmpty ? "" : " WHERE \(filter)", filterParameters)
        }
        let metadata = await SchemaRegistry.shared.register(T.self)
        guard let primaryKey = metadata.fields.first(where: \.isPrimaryKey)?.databaseName else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }
        let key = qualifiedColumn(primaryKey)
        var rows = self
        rows.lockClause = nil
        return (" WHERE \(key) IN (\(rows.selectSQL(selectClause: key)))", parameters)
    }

    private func countAffected(_ statement: String, _ parameters: [PostgresData]) async throws -> Int {
        let sql = renumberPlaceholders(in: "WITH affected AS (\(statement) RETURNING 1) SELECT count(*) AS count FROM affected")
        let counts = try await executor.executeQuery(sql: sql, parameters: parameters) { row in
            row.makeRandomAccess()[data: "count"].int ?? 0
        }
        return counts.first ?? 0
    }
}
