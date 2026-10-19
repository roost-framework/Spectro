import Foundation
import PostgresNIO
import AsyncKit

/// Generic database repository that works with any Schema type.
///
/// `GenericDatabaseRepo` provides a type-safe, actor-based data access layer for PostgreSQL.
/// It implements the Repository pattern with full CRUD operations, query building, and transaction support.
public actor GenericDatabaseRepo: Repo {
    private let connection: DatabaseConnection

    public init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Query

    public nonisolated func query<T: Schema>(_ schema: T.Type) -> Query<T> {
        Query(schema: schema, executor: connection)
    }

    // MARK: - Raw SQL

    public func executeRawSQL(_ sql: String) async throws {
        try await connection.executeUpdate(sql: sql)
    }

    /// Execute a raw SQL query with parameters and return raw PostgresRow results.
    /// Useful for junction table queries in many-to-many preloading.
    public func executeRawQuery(
        sql: String,
        parameters: [PostgresData] = []
    ) async throws -> [PostgresRow] {
        try await connection.executeQuery(
            sql: sql,
            parameters: parameters,
            resultMapper: { $0 }
        )
    }

    // MARK: - CRUD

    public func get<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T? {
        let metadata = await SchemaRegistry.shared.register(schema)

        guard let primaryKey = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        var sql = "SELECT * FROM \(metadata.tableName.quoted) WHERE \(primaryKey.snakeCase().quoted) = $1"
        if let sdf = metadata.softDeleteField { sql += " AND \(sdf.quoted) IS NULL" }

        let rows = try await connection.executeQuery(
            sql: sql,
            parameters: [id.toPostgresData()],
            resultMapper: { $0 }
        )

        guard let row = rows.first else { return nil }
        return try await mapRowToSchema(row, schema: schema)
    }

    public func all<T: Schema>(_ schema: T.Type) async throws -> [T] {
        let metadata = await SchemaRegistry.shared.register(schema)
        var sql = "SELECT * FROM \(metadata.tableName.quoted)"
        if let sdf = metadata.softDeleteField { sql += " WHERE \(sdf.quoted) IS NULL" }
        let rows = try await connection.executeQuery(sql: sql, resultMapper: { $0 })

        var results: [T] = []
        for row in rows {
            results.append(try await mapRowToSchema(row, schema: schema))
        }
        return results
    }

    public func insert<T: Schema>(_ instance: T, includePrimaryKey: Bool = false) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(T.self)
        let data = SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)

        let columns = data.keys.map { $0.quoted }.joined(separator: ", ")
        let placeholders = (1...data.count).map { "$\($0)" }.joined(separator: ", ")
        let values = Array(data.values)

        let sql = """
            INSERT INTO \(metadata.tableName.quoted) (\(columns))
            VALUES (\(placeholders))
            RETURNING *
            """

        let rows = try await connection.executeQuery(
            sql: sql,
            parameters: values,
            resultMapper: { $0 }
        )

        guard let row = rows.first else {
            throw SpectroError.databaseError(reason: "Insert did not return a row")
        }

        return try await mapRowToSchema(row, schema: T.self)
    }

    public func upsert<T: Schema>(_ instance: T, conflictTarget: ConflictTarget, set: [String]?, includePrimaryKey: Bool = false) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(T.self)
        let data = SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)

        let columns = data.keys.map { $0.quoted }.joined(separator: ", ")
        let placeholders = (1...data.count).map { "$\($0)" }.joined(separator: ", ")
        let values = Array(data.values)

        // Build ON CONFLICT clause
        let conflictClause: String
        switch conflictTarget {
        case .columns(let cols):
            let quotedCols = cols.map { $0.snakeCase().quoted }.joined(separator: ", ")
            conflictClause = "ON CONFLICT (\(quotedCols))"
        case .constraint(let name):
            conflictClause = "ON CONFLICT ON CONSTRAINT \(name.quoted)"
        }

        // Determine which columns to update on conflict
        let updateColumns: [String]
        if let set = set {
            guard !set.isEmpty else {
                throw SpectroError.invalidSchema(reason: "upsert 'set' parameter must not be an empty array; use nil to update all columns")
            }
            updateColumns = set.map { $0.snakeCase() }
        } else {
            // Update all non-primary-key columns
            updateColumns = Array(data.keys)
        }

        let setClause = updateColumns.map { col in
            "\(col.quoted) = EXCLUDED.\(col.quoted)"
        }.joined(separator: ", ")

        let sql = """
            INSERT INTO \(metadata.tableName.quoted) (\(columns))
            VALUES (\(placeholders))
            \(conflictClause) DO UPDATE SET \(setClause)
            RETURNING *
            """

        let rows = try await connection.executeQuery(
            sql: sql,
            parameters: values,
            resultMapper: { $0 }
        )

        guard let row = rows.first else {
            throw SpectroError.databaseError(reason: "Upsert did not return a row")
        }

        return try await mapRowToSchema(row, schema: T.self)
    }

    public func insertAll<T: Schema>(_ instances: [T], includePrimaryKey: Bool = false) async throws -> [T] {
        guard !instances.isEmpty else { return [] }

        let metadata = await SchemaRegistry.shared.register(T.self)

        // Extract data from the first instance to determine column order
        let firstData = SchemaMapper.extractData(from: instances[0], metadata: metadata, excludePrimaryKey: !includePrimaryKey)
        let columnNames = Array(firstData.keys)
        let columns = columnNames.map { $0.quoted }.joined(separator: ", ")
        let columnsPerRow = columnNames.count

        // Auto-batch at 1000 rows to stay under PostgreSQL's 65535 parameter limit
        let batchSize = 1000
        var allResults: [T] = []

        for batchStart in stride(from: 0, to: instances.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, instances.count)
            let batch = instances[batchStart..<batchEnd]

            var values: [PostgresData] = []
            var valueTuples: [String] = []
            var paramIndex = 1

            for instance in batch {
                let data = SchemaMapper.extractData(from: instance, metadata: metadata, excludePrimaryKey: !includePrimaryKey)
                let placeholders = (paramIndex..<(paramIndex + columnsPerRow)).map { "$\($0)" }.joined(separator: ", ")
                valueTuples.append("(\(placeholders))")

                // Add values in the same column order as the first instance
                for col in columnNames {
                    if let value = data[col] {
                        values.append(value)
                    } else {
                        values.append(PostgresData(type: .null, value: nil))
                    }
                }

                paramIndex += columnsPerRow
            }

            let sql = """
                INSERT INTO \(metadata.tableName.quoted) (\(columns))
                VALUES \(valueTuples.joined(separator: ", "))
                RETURNING *
                """

            let rows = try await connection.executeQuery(
                sql: sql,
                parameters: values,
                resultMapper: { $0 }
            )

            for row in rows {
                allResults.append(try await mapRowToSchema(row, schema: T.self))
            }
        }

        return allResults
    }

    public func update<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType, changes: [String: any Sendable]) async throws -> T {
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
        // A soft-deleted record is absent here, as in get().
        if let sdf = metadata.softDeleteField { whereClause += " AND \(sdf.quoted) IS NULL" }

        let sql = """
            UPDATE \(metadata.tableName.quoted)
            SET \(setClause.joined(separator: ", "))
            WHERE \(whereClause)
            RETURNING *
            """

        let rows = try await connection.executeQuery(
            sql: sql,
            parameters: values,
            resultMapper: { $0 }
        )

        guard let row = rows.first else {
            throw SpectroError.notFound(schema: metadata.tableName, id: String(describing: id))
        }

        return try await mapRowToSchema(row, schema: schema)
    }

    public func getOrFail<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws -> T {
        guard let result = try await get(schema, id: id) else {
            throw SpectroError.notFound(schema: schema.tableName, id: String(describing: id))
        }
        return result
    }

    public func delete<T: Schema>(_ schema: T.Type, id: some PrimaryKeyType) async throws {
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
            try await connection.executeUpdate(sql: sql, parameters: [id.toPostgresData()])
        } else {
            let sql = "DELETE FROM \(metadata.tableName.quoted) WHERE \(primaryKey.snakeCase().quoted) = $1"
            try await connection.executeUpdate(sql: sql, parameters: [id.toPostgresData()])
        }
    }

    public func transaction<T: Sendable>(_ work: @escaping @Sendable (any Repo) async throws -> T) async throws -> T {
        try await connection.transaction { context in
            let transactionRepo = TransactionRepo(context: context)
            return try await work(transactionRepo)
        }
    }

    // MARK: - Private

    private func mapRowToSchema<T: Schema>(_ row: PostgresRow, schema: T.Type) async throws -> T {
        let metadata = await SchemaRegistry.shared.register(schema)
        let randomAccess = row.makeRandomAccess()

        var values: [String: Any] = [:]
        for field in metadata.fields {
            let dbValue = randomAccess[data: field.databaseName]
            if let value = SchemaMapper.extractValue(from: dbValue, expectedType: field.type) {
                values[field.name] = value
            }
        }

        guard let builderType = T.self as? any SchemaBuilder.Type else {
            throw SpectroError.invalidSchema(
                reason: """
                    Schema \(T.self) must implement SchemaBuilder.
                    Add a `static func build(from values: [String: Any]) -> \(T.self)` \
                    or use the @Schema macro once available.
                    """
            )
        }

        let built = builderType.build(from: values)
        guard let result = built as? T else {
            throw SpectroError.invalidSchema(
                reason: "SchemaBuilder.build(from:) returned incompatible type for \(T.self)"
            )
        }
        return result
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
        let changes = try changeset.applyChanges()
        try changeset.validateConstraintDeclarations()
        guard !changes.isEmpty else {
            throw SpectroError.invalidSchema(
                reason: "Cannot insert from a changeset with no changes"
            )
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
            columns.append(dbColumn.quoted)
            values.append(try SchemaMapper.convertToPostgresData(value))
        }

        let placeholders = (1...columns.count).map { "$\($0)" }.joined(separator: ", ")
        let sql = """
            INSERT INTO \(metadata.tableName.quoted) (\(columns.joined(separator: ", ")))
            VALUES (\(placeholders))
            RETURNING *
            """

        let rows: [PostgresRow]
        do {
            rows = try await connection.executeQuery(
                sql: sql,
                parameters: values,
                resultMapper: { $0 }
            )
        } catch let error as SpectroError {
            throw changeset.constraintFailure(for: error) ?? error
        }

        guard let row = rows.first else {
            throw SpectroError.databaseError(reason: "Insert did not return a row")
        }

        return try await mapRowToSchema(row, schema: T.self)
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
        guard let existingData = changeset.data else {
            throw SpectroError.invalidSchema(
                reason: "Cannot update from a changeset with no existing data. Use insert(_:) for new records."
            )
        }

        let changes = try changeset.applyChanges()
        try changeset.validateConstraintDeclarations()
        guard !changes.isEmpty else {
            return existingData
        }

        let metadata = await SchemaRegistry.shared.register(T.self)
        guard let pkFieldName = metadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
        }

        guard let id = extractPrimaryKey(from: existingData, fieldName: pkFieldName) else {
            throw SpectroError.invalidSchema(
                reason: "Could not extract primary key value from \(T.self)"
            )
        }

        do {
            return try await update(T.self, id: id, changes: changes)
        } catch let error as SpectroError {
            throw changeset.constraintFailure(for: error) ?? error
        }
    }

}
