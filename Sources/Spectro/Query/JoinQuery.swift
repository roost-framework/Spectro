import Foundation
import PostgresNIO
import SpectroCommon

/// Query that includes joined tables and returns combined results
public struct JoinQuery<T: Schema, U: Schema>: Sendable {
    private let baseQuery: Query<T>
    private let joinedSchema: U.Type
    private let joinClause: JoinClause

    internal init(baseQuery: Query<T>, joinedSchema: U.Type, joinClause: JoinClause) {
        self.baseQuery = baseQuery
        self.joinedSchema = joinedSchema
        self.joinClause = joinClause
    }

    /// Execute join query and return tuples of (main, joined) records
    public func all() async throws -> [(T, U?)] {
        let main = JoinedProjection<T>(prefix: "__spectro_left")
        let joined = JoinedProjection<U>(prefix: "__spectro_right")
        let sql = baseQuery.buildSQL(selectClause: main.selection + ", " + joined.selection)

        return try await baseQuery.executor.executeQuery(
            sql: sql,
            parameters: baseQuery.parameters,
            resultMapper: { row in
                let columns = row.makeRandomAccess()
                let mainRecord = try main.decode(columns)
                let absent = try joinClause.type == .left && joined.isAbsent(columns)
                let joinedRecord = absent ? nil : try joined.decode(columns)
                return (mainRecord, joinedRecord)
            }
        )
    }

    /// Execute query and return first result
    public func first() async throws -> (T, U?)? {
        try await limit(1).all().first
    }

    /// Add where conditions to the join query
    public func `where`(_ condition: (JoinQueryBuilder<T, U>) -> QueryCondition) -> JoinQuery<T, U> {
        let builder = JoinQueryBuilder<T, U>()
        let queryCondition = condition(builder)

        let newBaseQuery = baseQuery.where { _ in queryCondition }

        return JoinQuery(baseQuery: newBaseQuery, joinedSchema: joinedSchema, joinClause: joinClause)
    }

    /// Add ordering to the join query
    public func orderBy<V>(_ field: (JoinQueryBuilder<T, U>) -> JoinField<V>, _ direction: OrderDirection = .asc) -> JoinQuery<T, U> {
        let builder = JoinQueryBuilder<T, U>()
        let joinField = field(builder)

        var newBaseQuery = baseQuery
        // qualifiedName is already pre-quoted ("table"."column")
        newBaseQuery.orderFields.append(OrderByClause(field: joinField.qualifiedName, direction: direction))

        return JoinQuery(baseQuery: newBaseQuery, joinedSchema: joinedSchema, joinClause: joinClause)
    }

    /// Limit results
    public func limit(_ count: Int) -> JoinQuery<T, U> {
        var newBaseQuery = baseQuery
        newBaseQuery.limitValue = count
        return JoinQuery(baseQuery: newBaseQuery, joinedSchema: joinedSchema, joinClause: joinClause)
    }

    /// Offset results
    public func offset(_ count: Int) -> JoinQuery<T, U> {
        var newBaseQuery = baseQuery
        newBaseQuery.offsetValue = count
        return JoinQuery(baseQuery: newBaseQuery, joinedSchema: joinedSchema, joinClause: joinClause)
    }

}

/// Each side gets short, unique aliases, independent of column names and PostgreSQL's
/// identifier length limit. Only a NULL primary key means an absent outer-join row.
private struct JoinedProjection<Model: Schema>: Sendable {
    let prefix: String
    let fields = SchemaRegistry.extractMetadata(from: Model.self).fields

    private func alias(_ index: Int) -> String { "\(prefix)_\(index)" }

    var selection: String {
        fields.enumerated().map { index, field in
            "\(Model.tableName.quoted).\(field.databaseName.quoted) AS \(alias(index).quoted)"
        }.joined(separator: ", ")
    }

    func isAbsent(_ row: PostgresRandomAccessRow) throws -> Bool {
        guard let index = fields.firstIndex(where: { $0.isPrimaryKey && !$0.isNullable }),
              row.contains(alias(index)) else {
            throw SpectroError.invalidSchema(reason: "A typed left join requires a projected, nonnullable primary key on \(Model.self)")
        }
        guard row[data: alias(index)].value == nil else { return false }
        // A malformed matched row with a NULL key must still fail decoding.
        return fields.indices.allSatisfy { row.contains(alias($0)) && row[data: alias($0)].value == nil }
    }

    func decode(_ row: PostgresRandomAccessRow) throws -> Model {
        var values: [String: Any] = [:]
        for (index, field) in fields.enumerated() {
            let column = "\(Model.tableName).\(field.databaseName)"
            guard row.contains(alias(index)) else {
                throw SpectroError.resultDecodingFailed(column: column, expectedType: String(describing: field.type))
            }
            let data = row[data: alias(index)]
            if data.value == nil && field.isNullable { continue }
            guard let value = SchemaMapper.extractValue(from: data, expectedType: field.type) else {
                throw SpectroError.resultDecodingFailed(column: column, expectedType: String(describing: field.type))
            }
            values[field.name] = value
        }
        return try Model.buildInstance(from: values)
    }
}

// MARK: - JoinQueryBuilder

/// Builder for creating conditions on joined queries
@dynamicMemberLookup
public struct JoinQueryBuilder<T: Schema, U: Schema>: Sendable {
    public init() {}

    public var main: JoinQueryField<T> { JoinQueryField<T>(tableName: T.tableName) }
    public var joined: JoinQueryField<U> { JoinQueryField<U>(tableName: U.tableName) }

    public subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> JoinField<V> {
        JoinField<V>(tableName: T.tableName, fieldName: extractFieldName(from: keyPath, schema: T.self))
    }
}

// MARK: - Query Extensions for JOIN execution

extension Query {
    /// Execute as a typed join query.
    ///
    /// Supports inner and left joins with distinct table names. Right joins cannot
    /// be represented by `(T, U?)`, since the main row can be absent.
    /// - Throws: `SpectroError.invalidSchema` for missing or unsupported joins.
    public func executeJoin<U: Schema>(with joinedType: U.Type) throws -> JoinQuery<T, U> {
        guard !joins.contains(where: { $0.type == .right }) else {
            throw SpectroError.invalidSchema(reason: "Typed right joins require an optional main model and are not supported by (T, U?). Reverse the query and use a left join.")
        }
        let tables = [T.tableName] + joins.map(\.table)
        guard Set(tables).count == tables.count else {
            throw SpectroError.invalidSchema(reason: "Typed self joins and repeated tables require table aliases, which are not supported yet.")
        }
        guard let joinClause = joins.first(where: { $0.table == joinedType.tableName }) else {
            throw SpectroError.invalidSchema(
                reason: "No join found for schema type \(joinedType). Call .join() or .leftJoin() before .executeJoin(with:)."
            )
        }
        let mainFields = SchemaRegistry.extractMetadata(from: T.self).fields
        let joinedFields = SchemaRegistry.extractMetadata(from: U.self).fields
        guard !mainFields.isEmpty, !joinedFields.isEmpty else {
            throw SpectroError.invalidSchema(reason: "Typed joins require mapped fields on both schemas.")
        }
        if joinClause.type == .left && !joinedFields.contains(where: { $0.isPrimaryKey && !$0.isNullable }) {
            throw SpectroError.invalidSchema(reason: "A typed left join requires a nonnullable primary key on \(U.self).")
        }
        return JoinQuery(baseQuery: self, joinedSchema: joinedType, joinClause: joinClause)
    }

    /// Convenience: join and execute in one call
    public func joinAndExecute<U: Schema>(
        _ joinSchema: U.Type,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) async throws -> [(T, U?)] {
        try await self
            .join(joinSchema, on: condition)
            .executeJoin(with: joinSchema)
            .all()
    }

    /// Convenience: left join and execute in one call
    public func leftJoinAndExecute<U: Schema>(
        _ joinSchema: U.Type,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) async throws -> [(T, U?)] {
        try await self
            .leftJoin(joinSchema, on: condition)
            .executeJoin(with: joinSchema)
            .all()
    }
}
