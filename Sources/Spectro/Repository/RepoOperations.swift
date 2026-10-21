import Foundation
import PostgresNIO

/// The CRUD statements shared by `GenericDatabaseRepo` and `TransactionRepo`.
///
/// Every statement runs on `executor`: the pool for `GenericDatabaseRepo`, the pinned
/// transaction connection for `TransactionRepo`.
struct RepoOperations: Sendable {
    let executor: any QueryExecutor

    func rows(_ sql: String, _ parameters: [PostgresData] = []) async throws -> [PostgresRow] {
        try await executor.executeQuery(sql: sql, parameters: parameters, resultMapper: { $0 })
    }

    func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T? {
        let metadata = await SchemaRegistry.shared.register(schema)

        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        var sql = "SELECT * FROM \(metadata.tableName.quoted) WHERE \(primaryKey.snakeCase().quoted) = $1"
        if let sdf = metadata.softDeleteField { sql += " AND \(sdf.quoted) IS NULL" }

        guard let row = try await rows(sql, [id.toPostgresData()]).first else { return nil }
        return try await T.from(row: row)
    }

    func all<T: Schema>(_ schema: T.Type) async throws -> [T] {
        let metadata = await SchemaRegistry.shared.register(schema)
        var sql = "SELECT * FROM \(metadata.tableName.quoted)"
        if let sdf = metadata.softDeleteField { sql += " WHERE \(sdf.quoted) IS NULL" }

        var results: [T] = []
        for row in try await rows(sql) {
            results.append(try await T.from(row: row))
        }
        return results
    }

    func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(T.self)
        let data = try SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)
        return try await insertRow(into: metadata.tableName, columns: Array(data.keys), values: Array(data.values))
    }

    func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]?, includePrimaryKey: Bool) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(T.self)
        let data = try SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)

        guard !data.isEmpty else {
            throw SpectroError.invalidSchema(reason: "Cannot upsert \(T.self) without columns to insert")
        }
        let columns = data.keys.map { $0.quoted }.joined(separator: ", ")
        let placeholders = (1...data.count).map { "$\($0)" }.joined(separator: ", ")
        let values = Array(data.values)

        if set?.isEmpty == true {
            throw SpectroError.invalidSchema(reason: "upsert 'set' parameter must not be an empty array; use nil to update all columns")
        }
        // Without `set`, every inserted column is updated on conflict.
        let conflictClause = try ConflictAction.replace(on: conflictTarget, columns: set).sql(insertedColumns: Array(data.keys))

        let sql = """
            INSERT INTO \(metadata.tableName.quoted) (\(columns))
            VALUES (\(placeholders))
            \(conflictClause)
            RETURNING *
            """

        guard let row = try await rows(sql, values).first else {
            throw SpectroError.databaseError(reason: "Upsert did not return a row")
        }
        return try await T.from(row: row)
    }

    /// Insert `instances` in batches. With `onConflict`, the records returned are those inserted or updated.
    func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool, onConflict: ConflictAction? = nil) async throws -> [T] {
        guard !instances.isEmpty else { return [] }

        let metadata = await SchemaRegistry.shared.register(T.self)

        // The first instance determines the column order.
        let firstData = try SchemaMapper.extractData(from: instances[0], metadata: metadata, excludePrimaryKey: !includePrimaryKey)
        let columnNames = Array(firstData.keys)
        let columns = columnNames.map { $0.quoted }.joined(separator: ", ")
        let columnsPerRow = columnNames.count
        guard columnsPerRow > 0 else {
            throw SpectroError.invalidSchema(reason: "Cannot insert \(T.self) records without columns; insert them one at a time")
        }

        let conflictClause = try onConflict.map { try $0.sql(insertedColumns: columnNames) + "\n" } ?? ""

        // Batches stay under PostgreSQL's 65535 parameter limit.
        let batchSize = max(1, min(1000, 65_535 / columnsPerRow))
        var allResults: [T] = []

        for batchStart in stride(from: 0, to: instances.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, instances.count)
            let batch = instances[batchStart..<batchEnd]

            var values: [PostgresData] = []
            var valueTuples: [String] = []
            var paramIndex = 1

            for instance in batch {
                let data = try SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)
                let placeholders = (paramIndex..<(paramIndex + columnsPerRow)).map { "$\($0)" }.joined(separator: ", ")
                valueTuples.append("(\(placeholders))")

                for col in columnNames {
                    values.append(data[col] ?? PostgresData(type: .null, value: nil))
                }

                paramIndex += columnsPerRow
            }

            let sql = """
                INSERT INTO \(metadata.tableName.quoted) (\(columns))
                VALUES \(valueTuples.joined(separator: ", "))
                \(conflictClause)RETURNING *
                """

            for row in try await rows(sql, values) {
                allResults.append(try await T.from(row: row))
            }
        }

        return allResults
    }

    /// Update the record `id`. With `lock`, only while the lock column holds its value, or
    /// throw `SpectroError.staleRecord`.
    func update<T: Schema>(
        _ schema: T.Type,
        id: some PrimaryKeyType,
        changes: [String: any Sendable],
        lock: (column: String, value: PostgresData)? = nil
    ) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(schema)

        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(schema) has no primary key field")
        }

        var setClause: [String] = []
        var values: [PostgresData] = []
        var paramIndex = 1

        let knownColumns = Set(metadata.fields.map { $0.databaseName })
        for (column, value) in changes {
            let dbColumn = metadata.fields.first { $0.name == column }?.databaseName ?? column.snakeCase()
            guard knownColumns.contains(dbColumn) else {
                throw SpectroError.invalidSchema(reason: "Unknown column '\(column)' on \(T.self)")
            }
            setClause.append("\(dbColumn.quoted) = $\(paramIndex)")
            values.append(try SchemaMapper.convertToPostgresData(value))
            paramIndex += 1
        }

        values.append(id.toPostgresData())

        var whereClause = "\(primaryKey.snakeCase().quoted) = $\(paramIndex)"
        if let lock {
            values.append(lock.value)
            whereClause += " AND \(lock.column.quoted) = $\(paramIndex + 1)"
        }
        // A soft-deleted record is absent here, as in get().
        if let sdf = metadata.softDeleteField { whereClause += " AND \(sdf.quoted) IS NULL" }

        let sql = """
            UPDATE \(metadata.tableName.quoted)
            SET \(setClause.joined(separator: ", "))
            WHERE \(whereClause)
            RETURNING *
            """

        guard let row = try await rows(sql, values).first else {
            if lock != nil { throw SpectroError.staleRecord(schema: metadata.tableName, id: String(describing: id)) }
            throw SpectroError.notFound(schema: metadata.tableName, id: String(describing: id))
        }
        return try await T.from(row: row)
    }

    func getOrFail<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T {
        guard let result = try await get(schema, id: id) else {
            throw SpectroError.notFound(schema: schema.tableName, id: String(describing: id))
        }
        return result
    }

    func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws {
        let metadata = await SchemaRegistry.shared.register(schema)

        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        if let sdf = metadata.softDeleteField {
            let sql = """
                UPDATE \(metadata.tableName.quoted)
                SET \(sdf.quoted) = NOW()
                WHERE \(primaryKey.snakeCase().quoted) = $1
                AND \(sdf.quoted) IS NULL
                """
            _ = try await rows(sql, [id.toPostgresData()])
        } else {
            let sql = "DELETE FROM \(metadata.tableName.quoted) WHERE \(primaryKey.snakeCase().quoted) = $1"
            _ = try await rows(sql, [id.toPostgresData()])
        }
    }

    // MARK: - Changesets

    func insert<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        let changes = try changeset.applyChanges()
        try changeset.validateConstraintDeclarations()
        guard !changes.isEmpty else {
            throw SpectroError.invalidSchema(reason: "Cannot insert from a changeset with no changes")
        }

        let metadata = await SchemaRegistry.shared.register(T.self)
        let knownColumns = Set(metadata.fields.map { $0.databaseName })

        var columns: [String] = []
        var values: [PostgresData] = []
        for (field, value) in changes {
            let dbColumn = metadata.fields.first { $0.name == field }?.databaseName ?? field.snakeCase()
            guard knownColumns.contains(dbColumn) else {
                throw SpectroError.invalidSchema(reason: "Unknown column '\(field)' on \(T.self)")
            }
            columns.append(dbColumn)
            values.append(try SchemaMapper.convertToPostgresData(value))
        }

        do {
            return try await insertRow(into: metadata.tableName, columns: columns, values: values)
        } catch let error as SpectroError {
            throw changeset.constraintFailure(for: error) ?? error
        }
    }

    func update<T: Schema>(_ changeset: Changeset<T>) async throws -> T {
        guard let existingData = changeset.data else {
            throw SpectroError.invalidSchema(
                reason: "Cannot update from a changeset with no existing data. Use insert(_:) for new records."
            )
        }

        var changes = try changeset.applyChanges()
        try changeset.validateConstraintDeclarations()
        let metadata = await SchemaRegistry.shared.register(T.self)

        var lock: (column: String, value: PostgresData)?
        if let field = changeset.lockField {
            guard let column = metadata.fields.first(where: { $0.name == field })?.databaseName,
                  let version = changeset.extractFieldValue(from: existingData, named: field) as? Int else {
                throw SpectroError.invalidField(schema: String(describing: T.self), field: field)
            }
            changes[field] = version + 1
            lock = (column, PostgresData(int: version))
        }
        guard !changes.isEmpty else {
            return existingData
        }

        guard let pkFieldName = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        guard let id = extractPrimaryKey(from: existingData, fieldName: pkFieldName) else {
            throw SpectroError.invalidSchema(
                reason: "Could not extract primary key value from \(T.self)"
            )
        }

        do {
            return try await update(T.self, id: id, changes: changes, lock: lock)
        } catch let error as SpectroError {
            throw changeset.constraintFailure(for: error) ?? error
        }
    }

    // MARK: - Private

    /// Insert one row and decode the returned record. With no columns, every column takes its default.
    private func insertRow<T: Schema>(into table: String, columns: [String], values: [PostgresData]) async throws -> T {
        let sql: String
        if columns.isEmpty {
            sql = "INSERT INTO \(table.quoted) DEFAULT VALUES RETURNING *"
        } else {
            let placeholders = (1...columns.count).map { "$\($0)" }.joined(separator: ", ")
            sql = """
                INSERT INTO \(table.quoted) (\(columns.map(\.quoted).joined(separator: ", ")))
                VALUES (\(placeholders))
                RETURNING *
                """
        }

        guard let row = try await rows(sql, values).first else {
            throw SpectroError.databaseError(reason: "Insert did not return a row")
        }
        return try await T.from(row: row)
    }
}
