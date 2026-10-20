import Foundation
import PostgresKit
import SpectroCommon

/// Closure-based query builder for beautiful, type-safe database operations
///
/// Usage:
/// ```swift
/// let users = try await repo.query(User.self)
///     .where { $0.name == "John" && $0.age > 18 }
///     .orderBy(\.createdAt, .desc)
///     .limit(10)
///     .all()
/// ```
public struct Query<T: Schema>: Sendable {
    private let schema: T.Type
    internal let executor: any QueryExecutor
    // Read through buildWhereClause(), which adds the soft-delete filter.
    private var whereClause: String = ""
    private var whereParameters: [PostgresData] = []
    // Bindings follow SQL clause order, independently of builder call order.
    internal var parameters: [PostgresData] {
        joins.flatMap(\.parameters) + whereParameters
    }
    internal var orderFields: [OrderByClause] = []
    internal var limitValue: Int?
    internal var offsetValue: Int?
    private var selectedFields: Set<String>?
    internal var joins: [JoinClause] = []
    internal var referencedTables: Set<JoinTableReference> = []
    internal var groupByFields: [String] = []
    internal var havingClause: String = ""
    internal var havingParameters: [PostgresData] = []
    private var includeSoftDeleted: Bool = false
    internal var lockClause: String?

    internal init(schema: T.Type, executor: any QueryExecutor) {
        self.schema = schema
        self.executor = executor
    }

    /// Bypass the automatic soft-delete filter on the queried and joined tables, returning all records including soft-deleted ones.
    public func withDeleted() -> Query<T> {
        var copy = self
        copy.includeSoftDeleted = true
        return copy
    }

    // MARK: - Row Locks

    /// Lock the queried table's selected rows until the transaction ends, like Ecto's `lock`.
    ///
    /// ```swift
    /// try await repo.transaction { tx in
    ///     let job = try await tx.query(Job.self)
    ///         .where { $0.state == "queued" }
    ///         .orderBy { $0.insertedAt }
    ///         .limit(1)
    ///         .lock(.update, .skipLocked)
    ///         .first()
    /// }
    /// ```
    ///
    /// Only the queried table is locked, so outer joins are allowed. Outside a transaction the
    /// lock is released as soon as the statement ends. Counts and aggregates ignore the lock,
    /// as PostgreSQL does not lock aggregated rows.
    public func lock(_ strength: RowLockStrength = .update, _ wait: RowLockWait = .wait) -> Query<T> {
        var copy = self
        copy.lockClause = " FOR \(strength.sql) OF \(T.tableName.quoted)\(wait.sql)"
        return copy
    }

    // MARK: - Where Clauses

    public func `where`(_ condition: (QueryBuilder<T>) -> QueryCondition) -> Query<T> {
        var copy = self
        let builder = QueryBuilder<T>()
        let queryCondition = condition(builder)

        if !copy.whereClause.isEmpty {
            copy.whereClause += " AND "
        }
        // Parenthesize each clause so an OR inside it cannot absorb the clauses
        // and soft-delete filter that are ANDed around it.
        copy.whereClause += "(\(queryCondition.sql))"
        copy.whereParameters.append(contentsOf: queryCondition.parameters)
        copy.referencedTables.formUnion(queryCondition.referencedTables)

        return copy
    }

    // MARK: - Joins

    public func join<U: Schema>(
        _ joinSchema: U.Type,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        join(joinSchema, as: nil, on: condition)
    }

    public func join<U: Schema>(
        _ joinSchema: U.Type,
        as alias: String?,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        var copy = self
        let builder = JoinBuilder<T, U>(rightTableName: alias ?? U.tableName)
        let joinCondition = condition(builder)
        copy.joins.append(JoinClause(
            type: .inner,
            table: joinSchema.tableName,
            alias: alias,
            softDeleteColumn: U.softDeleteColumn,
            condition: joinCondition.sql,
            parameters: joinCondition.parameters,
            referencedTables: joinCondition.referencedTables
        ))
        return copy
    }

    public func leftJoin<U: Schema>(
        _ joinSchema: U.Type,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        leftJoin(joinSchema, as: nil, on: condition)
    }

    public func leftJoin<U: Schema>(
        _ joinSchema: U.Type,
        as alias: String?,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        var copy = self
        let builder = JoinBuilder<T, U>(rightTableName: alias ?? U.tableName)
        let joinCondition = condition(builder)
        copy.joins.append(JoinClause(
            type: .left,
            table: joinSchema.tableName,
            alias: alias,
            softDeleteColumn: U.softDeleteColumn,
            condition: joinCondition.sql,
            parameters: joinCondition.parameters,
            referencedTables: joinCondition.referencedTables
        ))
        return copy
    }

    public func rightJoin<U: Schema>(
        _ joinSchema: U.Type,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        rightJoin(joinSchema, as: nil, on: condition)
    }

    public func rightJoin<U: Schema>(
        _ joinSchema: U.Type,
        as alias: String?,
        on condition: (JoinBuilder<T, U>) -> QueryCondition
    ) -> Query<T> {
        var copy = self
        let builder = JoinBuilder<T, U>(rightTableName: alias ?? U.tableName)
        let joinCondition = condition(builder)
        copy.joins.append(JoinClause(
            type: .right,
            table: joinSchema.tableName,
            alias: alias,
            softDeleteColumn: U.softDeleteColumn,
            condition: joinCondition.sql,
            parameters: joinCondition.parameters,
            referencedTables: joinCondition.referencedTables
        ))
        return copy
    }

    public func joinThrough<U: Schema, Junction: Schema>(
        _ targetSchema: U.Type,
        through junctionSchema: Junction.Type,
        on condition: (ThroughJoinBuilder<T, U, Junction>) -> (QueryCondition, QueryCondition)
    ) -> Query<T> {
        var copy = self
        let builder = ThroughJoinBuilder<T, U, Junction>()
        let (firstJoin, secondJoin) = condition(builder)

        copy.joins.append(JoinClause(
            type: .inner,
            table: junctionSchema.tableName,
            softDeleteColumn: Junction.softDeleteColumn,
            condition: firstJoin.sql,
            parameters: firstJoin.parameters,
            referencedTables: firstJoin.referencedTables
        ))

        copy.joins.append(JoinClause(
            type: .inner,
            table: targetSchema.tableName,
            softDeleteColumn: U.softDeleteColumn,
            condition: secondJoin.sql,
            parameters: secondJoin.parameters,
            referencedTables: secondJoin.referencedTables
        ))

        return copy
    }

    // MARK: - Ordering
    //
    // Field names are quoted at storage time so buildOrderClause() can use
    // them verbatim without risk of double-quoting qualified join fields.

    public func orderBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>) -> Query<T> {
        var copy = self
        let queryField = field(QueryBuilder<T>())
        copy.orderFields.append(OrderByClause(
            field: queryField.qualifiedName,
            direction: .asc
        ))
        return copy
    }

    public func orderBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>, _ direction: OrderDirection) -> Query<T> {
        var copy = self
        let queryField = field(QueryBuilder<T>())
        copy.orderFields.append(OrderByClause(
            field: queryField.qualifiedName,
            direction: direction
        ))
        return copy
    }

    public func orderBy<V1, V2>(
        _ field1: (QueryBuilder<T>) -> QueryField<V1>,
        _ direction1: OrderDirection = .asc,
        then field2: (QueryBuilder<T>) -> QueryField<V2>,
        _ direction2: OrderDirection = .asc
    ) -> Query<T> {
        var copy = self
        let builder = QueryBuilder<T>()
        copy.orderFields.append(OrderByClause(field: field1(builder).qualifiedName, direction: direction1))
        copy.orderFields.append(OrderByClause(field: field2(builder).qualifiedName, direction: direction2))
        return copy
    }

    // MARK: - Field Selection

    public func select<V>(_ selector: (QueryBuilder<T>) -> QueryField<V>) -> TupleQuery<T, V> {
        let field = selector(QueryBuilder<T>())
        return TupleQuery<T, V>(baseQuery: self, selectedFields: [field.name])
    }

    public func select<V1, V2>(_ selector: (QueryBuilder<T>) -> (QueryField<V1>, QueryField<V2>)) -> TupleQuery<T, Tuple2<V1, V2>> {
        let (f1, f2) = selector(QueryBuilder<T>())
        return TupleQuery<T, Tuple2<V1, V2>>(
            baseQuery: self,
            selectedFields: [f1.name, f2.name]
        )
    }

    public func select<V1, V2, V3>(_ selector: (QueryBuilder<T>) -> (QueryField<V1>, QueryField<V2>, QueryField<V3>)) -> TupleQuery<T, Tuple3<V1, V2, V3>> {
        let (f1, f2, f3) = selector(QueryBuilder<T>())
        return TupleQuery<T, Tuple3<V1, V2, V3>>(
            baseQuery: self,
            selectedFields: [f1.name, f2.name, f3.name]
        )
    }

    public func select<V1, V2, V3, V4>(_ selector: (QueryBuilder<T>) -> (QueryField<V1>, QueryField<V2>, QueryField<V3>, QueryField<V4>)) -> TupleQuery<T, Tuple4<V1, V2, V3, V4>> {
        let (f1, f2, f3, f4) = selector(QueryBuilder<T>())
        return TupleQuery<T, Tuple4<V1, V2, V3, V4>>(
            baseQuery: self,
            selectedFields: [f1.name, f2.name, f3.name, f4.name]
        )
    }

    public func selectFields<V>(_ field: (QueryBuilder<T>) -> QueryField<V>) -> Query<T> {
        var copy = self
        let queryField = field(QueryBuilder<T>())
        if copy.selectedFields == nil { copy.selectedFields = [] }
        copy.selectedFields?.insert(queryField.name)
        return copy
    }

    // MARK: - Pagination

    public func limit(_ count: Int) -> Query<T> {
        var copy = self
        copy.limitValue = count
        return copy
    }

    public func offset(_ count: Int) -> Query<T> {
        var copy = self
        copy.offsetValue = count
        return copy
    }

    // MARK: - GROUP BY / HAVING

    public func groupBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>) -> Query<T> {
        var copy = self
        let queryField = field(QueryBuilder<T>())
        copy.groupByFields.append(queryField.name)
        return copy
    }

    public func groupBy<V1, V2>(
        _ f1: (QueryBuilder<T>) -> QueryField<V1>,
        _ f2: (QueryBuilder<T>) -> QueryField<V2>
    ) -> Query<T> {
        var copy = self
        let builder = QueryBuilder<T>()
        copy.groupByFields.append(f1(builder).name)
        copy.groupByFields.append(f2(builder).name)
        return copy
    }

    public func having(_ condition: (QueryBuilder<T>) -> QueryCondition) -> Query<T> {
        var copy = self
        let builder = QueryBuilder<T>()
        let cond = condition(builder)
        if !copy.havingClause.isEmpty {
            copy.havingClause += " AND "
        }
        copy.havingClause += "(\(cond.sql))"
        copy.havingParameters.append(contentsOf: cond.parameters)
        copy.referencedTables.formUnion(cond.referencedTables)
        return copy
    }

    // MARK: - Relationship Preloading
    //
    // Keys paths must be WritableKeyPath so PreloadQuery can inject loaded data
    // back into the struct via entity[keyPath: \.$posts] = loadedRelation.
    // The foreignKey parameter names the column on the *related* table that
    // holds the parent ID (HasMany / HasOne), or the column on *this* table
    // that holds the related ID (BelongsTo). When omitted, the convention
    // "<ParentTypeName>Id" is used (e.g. User → "userId").

    /// Load a has-many or many-to-many relationship in one query for all results.
    /// `customize` adjusts the query that loads the related records; see `PreloadQuery`.
    public func preload<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: self, preloaders: []).preload(keyPath, foreignKey: foreignKey, customize)
    }

    /// Load a has-one or belongs-to relationship in one query for all results.
    /// `customize` adjusts the query that loads the related records; see `PreloadQuery`.
    public func preload<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: self, preloaders: []).preload(keyPath, foreignKey: foreignKey, customize)
    }

    // MARK: - Execution

    public func all() async throws -> [T] {
        try validateJoins()
        guard !joins.contains(where: { $0.type == .right }) else {
            throw SpectroError.invalidSchema(reason: "A right join can have an absent main row and cannot return nonoptional models. Reverse the query and use a left join.")
        }
        let sql = buildSQL()
        let rows = try await executor.executeQuery(
            sql: sql,
            parameters: parameters,
            resultMapper: { $0 }
        )
        var results: [T] = []
        for row in rows {
            results.append(try await T.from(row: row, allowingMissingColumns: selectedFields != nil))
        }
        return results
    }

    public func first() async throws -> T? {
        try await limit(1).all().first
    }

    public func firstOrFail() async throws -> T {
        guard let result = try await first() else {
            throw SpectroError.notFound(schema: T.tableName, id: "(query)")
        }
        return result
    }

    public func count() async throws -> Int {
        try validateJoins()
        let sql = buildCountSQL()
        let results = try await executor.executeQuery(
            sql: sql,
            parameters: parameters,
            resultMapper: { row in
                let randomAccess = row.makeRandomAccess()
                guard let count = randomAccess[data: "count"].int else {
                    throw SpectroError.resultDecodingFailed(column: "count", expectedType: "Int")
                }
                return count
            }
        )
        return results.first ?? 0
    }

    /// Fetch a single page of results, issuing a COUNT query and a paginated SELECT.
    ///
    /// ```swift
    /// let page = try await repo.query(User.self)
    ///     .where { $0.isActive == true }
    ///     .orderBy("created_at", ascending: false)
    ///     .page(size: 20, page: 1)
    /// // page.items, page.totalCount, page.hasNextPage …
    /// ```
    public func page(size: Int, page: Int = 1) async throws -> Page<T> {
        let total = try await self.count()
        let items = try await self.limit(size).offset((page - 1) * size).all()
        return Page(items: items, totalCount: total, pageSize: size, pageNumber: page)
    }

    public func sum<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> Double? {
        try await aggregateExecute(function: "SUM", column: field(QueryBuilder<T>()).name)
    }

    public func avg<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> Double? {
        try await aggregateExecute(function: "AVG", column: field(QueryBuilder<T>()).name)
    }

    public func min<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> Double? {
        try await aggregateExecute(function: "MIN", column: field(QueryBuilder<T>()).name)
    }

    public func max<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> Double? {
        try await aggregateExecute(function: "MAX", column: field(QueryBuilder<T>()).name)
    }

    private func aggregateExecute(function: String, column: String) async throws -> Double? {
        try validateJoins()
        let sql = buildAggregateSQL(function: function, column: column)
        let results = try await executor.executeQuery(
            sql: sql,
            parameters: parameters,
            resultMapper: { row in
                row.makeRandomAccess()[data: "agg_result"].double
            }
        )
        return results.first ?? nil
    }

    // MARK: - Grouped Aggregates

    public func groupedSum<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> [GroupedResult] {
        try await groupedAggregateExecute(function: "SUM", column: field(QueryBuilder<T>()).name)
    }

    public func groupedAvg<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> [GroupedResult] {
        try await groupedAggregateExecute(function: "AVG", column: field(QueryBuilder<T>()).name)
    }

    public func groupedMin<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> [GroupedResult] {
        try await groupedAggregateExecute(function: "MIN", column: field(QueryBuilder<T>()).name)
    }

    public func groupedMax<V: Numeric>(_ field: (QueryBuilder<T>) -> QueryField<V>) async throws -> [GroupedResult] {
        try await groupedAggregateExecute(function: "MAX", column: field(QueryBuilder<T>()).name)
    }

    public func groupedCount() async throws -> [GroupedResult] {
        try await groupedAggregateExecute(function: "COUNT", column: "*")
    }

    private func groupedAggregateExecute(function: String, column: String) async throws -> [GroupedResult] {
        try validateJoins()
        guard !groupByFields.isEmpty else {
            throw SpectroError.invalidQuery("grouped\(function.lowercased().capitalized)() requires at least one groupBy() clause")
        }

        let sql = buildGroupedAggregateSQL(function: function, column: column)
        let allParameters = parameters + havingParameters

        return try await executor.executeQuery(
            sql: sql,
            parameters: allParameters,
            resultMapper: { row in
                let randomAccess = row.makeRandomAccess()
                var group: [String: String] = [:]
                for col in self.groupByFields {
                    if let str = randomAccess[data: col].string {
                        group[col] = str
                    } else if let b = randomAccess[data: col].bool {
                        group[col] = b ? "true" : "false"
                    } else if let i = randomAccess[data: col].int {
                        group[col] = String(i)
                    } else if let d = randomAccess[data: col].double {
                        group[col] = String(d)
                    }
                }
                let value = randomAccess[data: "agg_result"].double
                return GroupedResult(group: group, value: value)
            }
        )
    }

    // MARK: - SQL Building

    internal func buildSQL(selectClause: String? = nil) -> String {
        renumberPlaceholders(in: selectSQL(selectClause: selectClause))
    }

    /// The SELECT with unnumbered `?` placeholders, for embedding in another statement.
    /// Its bindings are `parameters`.
    internal func selectSQL(selectClause: String? = nil) -> String {
        let table = T.tableName.quoted
        let selection = selectClause ?? buildSelectClause()
        let joinClause = buildJoinClause()
        let orderClause = buildOrderClause()
        let limitClause = buildLimitClause()
        let effectiveWhere = buildWhereClause()

        var sql = "SELECT \(selection) FROM \(table)"

        if !joinClause.isEmpty { sql += " \(joinClause)" }
        if !effectiveWhere.isEmpty { sql += " WHERE \(effectiveWhere)" }
        if !orderClause.isEmpty { sql += " ORDER BY \(orderClause)" }
        if !limitClause.isEmpty { sql += limitClause }
        if let lockClause { sql += lockClause }

        return sql
    }

    internal func buildCountSQL() -> String {
        let table = T.tableName.quoted
        let joinClause = buildJoinClause()
        let effectiveWhere = buildWhereClause()

        var sql = "SELECT COUNT(*) as count FROM \(table)"

        if !joinClause.isEmpty { sql += " \(joinClause)" }
        if !effectiveWhere.isEmpty { sql += " WHERE \(effectiveWhere)" }

        return renumberPlaceholders(in: sql)
    }

    internal func buildWhereClause() -> String {
        if includeSoftDeleted { return whereClause }
        guard let sdf = T.softDeleteColumn else { return whereClause }
        let column = joins.isEmpty ? sdf.quoted : "\(T.tableName.quoted).\(sdf.quoted)"
        let sdFilter = "\(column) IS NULL"
        return whereClause.isEmpty ? sdFilter : "\(sdFilter) AND \(whereClause)"
    }

    private func buildAggregateSQL(function: String, column: String) -> String {
        let table = T.tableName.quoted
        let joinClause = buildJoinClause()
        let effectiveWhere = buildWhereClause()

        var sql = "SELECT CAST(\(function)(\(qualifiedColumn(column))) AS DOUBLE PRECISION) as agg_result FROM \(table)"

        if !joinClause.isEmpty { sql += " \(joinClause)" }
        if !effectiveWhere.isEmpty { sql += " WHERE \(effectiveWhere)" }

        return renumberPlaceholders(in: sql)
    }

    private func buildGroupedAggregateSQL(function: String, column: String) -> String {
        let table = T.tableName.quoted
        let groupColumns = groupByFields.map { qualifiedColumn($0) }.joined(separator: ", ")
        let joinClause = buildJoinClause()
        let effectiveWhere = buildWhereClause()

        let colExpr = column == "*" ? "*" : qualifiedColumn(column)
        var sql = "SELECT \(groupColumns), CAST(\(function)(\(colExpr)) AS DOUBLE PRECISION) as agg_result FROM \(table)"

        if !joinClause.isEmpty { sql += " \(joinClause)" }
        if !effectiveWhere.isEmpty { sql += " WHERE \(effectiveWhere)" }
        sql += " GROUP BY \(groupColumns)"
        if !havingClause.isEmpty { sql += " HAVING \(havingClause)" }

        let orderClause = buildOrderClause()
        if !orderClause.isEmpty { sql += " ORDER BY \(orderClause)" }
        let limitClause = buildLimitClause()
        if !limitClause.isEmpty { sql += limitClause }

        return renumberPlaceholders(in: sql)
    }

    private func buildSelectClause() -> String {
        guard let fields = selectedFields, !fields.isEmpty else {
            return joins.isEmpty ? "*" : "\(T.tableName.quoted).*"
        }
        // Keep result column names unqualified for decoding.
        return fields.sorted().map { qualifiedColumn($0) }.joined(separator: ", ")
    }

    internal func qualifiedColumn(_ column: String) -> String {
        "\(T.tableName.quoted).\(column.quoted)"
    }

    internal func buildJoinClause() -> String {
        guard !joins.isEmpty else { return "" }
        return joins.map { join in
            let table = join.table.quoted
            let identifier = join.identifier.quoted
            // Joining the filtered rows under the table's own name hides soft-deleted rows
            // for every join type; a filter in ON is wrong for a right join, in WHERE for a left.
            guard let sdf = join.softDeleteColumn, !includeSoftDeleted else {
                let source = join.alias.map { "\(table) AS \($0.quoted)" } ?? table
                return "\(join.type.sql) \(source) ON \(join.condition)"
            }
            return "\(join.type.sql) (SELECT * FROM \(table) WHERE \(sdf.quoted) IS NULL) AS \(identifier) ON \(join.condition)"
        }.joined(separator: " ")
    }

    /// Validate identifiers before sending SQL to the server. PostgreSQL silently truncates
    /// identifiers longer than 63 bytes, which can turn distinct aliases into duplicates.
    internal func validateJoins() throws {
        var tablesByIdentifier = [T.tableName: T.tableName]
        func validate(_ references: Set<JoinTableReference>, available: [String: String]) throws {
            for reference in references.sorted(by: { $0.identifier < $1.identifier }) {
                guard let actualTable = available[reference.identifier] else {
                    throw SpectroError.invalidSchema(reason: "Query refers to missing alias '\(reference.identifier)'.")
                }
                guard actualTable == reference.table else {
                    throw SpectroError.invalidSchema(reason: "Alias '\(reference.identifier)' refers to table '\(actualTable)', not '\(reference.table)'.")
                }
            }
        }
        for join in joins {
            if let alias = join.alias {
                let bytes = Array(alias.utf8)
                let valid = !bytes.isEmpty && bytes.count <= 63 &&
                    (bytes[0] == 95 || (65...90).contains(bytes[0]) || (97...122).contains(bytes[0])) &&
                    bytes.dropFirst().allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
                guard valid else {
                    throw SpectroError.invalidSchema(reason: "Invalid join alias '\(alias)'. Use an identifier of 1...63 ASCII letters, digits, or underscores, starting with a letter or underscore.")
                }
            }
            guard tablesByIdentifier[join.identifier] == nil else {
                throw SpectroError.invalidSchema(reason: "Duplicate join identifier '\(join.identifier)'. Give repeated tables distinct aliases.")
            }
            var available = tablesByIdentifier
            available[join.identifier] = join.table
            try validate(join.referencedTables, available: available)
            tablesByIdentifier = available
        }
        try validate(referencedTables, available: tablesByIdentifier)
    }

    internal func buildOrderClause() -> String {
        guard !orderFields.isEmpty else { return "" }
        // Fields are pre-quoted at storage time (see orderBy methods above)
        return orderFields.map { "\($0.field) \($0.direction.sql)" }
            .joined(separator: ", ")
    }

    internal func buildLimitClause() -> String {
        var clause = ""
        if let limit = limitValue {
            guard limit >= 0 else { return "" }
            clause += " LIMIT \(limit)"
        }
        if let offset = offsetValue {
            guard offset >= 0 else { return clause }
            clause += " OFFSET \(offset)"
        }
        return clause
    }

    // MARK: - Helpers

    internal func mapRowToSchema(_ row: PostgresRow) async throws -> T {
        try await T.from(row: row)
    }

    private func extractRelationshipName<Related>(from keyPath: KeyPath<T, SpectroLazyRelation<Related>>) -> String {
        if let name = T._keyPathToColumn[keyPath] { return name }
        if let propertyName = keyPath.propertyName { return propertyName }
        let keyPathString = String(describing: keyPath)
        if let match = keyPathString.range(of: #"\.\$?([a-zA-Z_][a-zA-Z0-9_]*)>*$"#, options: .regularExpression) {
            return String(keyPathString[match])
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ">", with: "")
        }
        return "unknown_relationship"
    }
}

// MARK: - TupleQuery

public struct TupleQuery<T: Schema, Result: Sendable>: Sendable {
    private let baseQuery: Query<T>
    // Stored as unquoted snake_case; quoted at SQL-build time
    private let selectedFields: [String]

    internal init(baseQuery: Query<T>, selectedFields: [String]) {
        self.baseQuery = baseQuery
        self.selectedFields = selectedFields
    }

    public func `where`(_ condition: (QueryBuilder<T>) -> QueryCondition) -> TupleQuery<T, Result> {
        TupleQuery<T, Result>(baseQuery: baseQuery.where(condition), selectedFields: selectedFields)
    }

    public func orderBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>) -> TupleQuery<T, Result> {
        TupleQuery<T, Result>(baseQuery: baseQuery.orderBy(field), selectedFields: selectedFields)
    }

    public func orderBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>, _ direction: OrderDirection) -> TupleQuery<T, Result> {
        TupleQuery<T, Result>(baseQuery: baseQuery.orderBy(field, direction), selectedFields: selectedFields)
    }

    public func limit(_ count: Int) -> TupleQuery<T, Result> {
        TupleQuery<T, Result>(baseQuery: baseQuery.limit(count), selectedFields: selectedFields)
    }

    public func offset(_ count: Int) -> TupleQuery<T, Result> {
        TupleQuery<T, Result>(baseQuery: baseQuery.offset(count), selectedFields: selectedFields)
    }

    public func all() async throws -> [Result] {
        try baseQuery.validateJoins()
        let sql = buildTupleSQL()
        return try await baseQuery.executor.executeQuery(
            sql: sql,
            parameters: baseQuery.parameters,
            resultMapper: { row in try mapRowToTuple(row) }
        )
    }

    internal func inspectionContext() throws -> (sql: String, parameters: [PostgresData], executor: any QueryExecutor) {
        try baseQuery.validateJoins()
        return (buildTupleSQL(), baseQuery.parameters, baseQuery.executor)
    }

    public func first() async throws -> Result? {
        try await limit(1).all().first
    }

    public func firstOrFail() async throws -> Result {
        guard let result = try await first() else {
            throw SpectroError.notFound(schema: T.tableName, id: "(query)")
        }
        return result
    }

    public func count() async throws -> Int {
        try await baseQuery.count()
    }

    private func buildTupleSQL() -> String {
        baseQuery.buildSQL(selectClause: selectedFields.map { baseQuery.qualifiedColumn($0) }.joined(separator: ", "))
    }

    private func mapRowToTuple(_ row: PostgresRow) throws -> Result {
        if let tupleBuildableType = Result.self as? any TupleBuildable.Type {
            let mapped = try TupleMapper.mapRow(row, selectedFields: selectedFields, to: tupleBuildableType)
            guard let result = mapped as? Result else {
                throw SpectroError.resultDecodingFailed(
                    column: selectedFields.joined(separator: ", "),
                    expectedType: String(describing: Result.self)
                )
            }
            return result
        }
        if selectedFields.count == 1 {
            do {
                return try extractValue(from: row.makeRandomAccess()[data: selectedFields[0]])
            } catch {
                throw SpectroError.resultDecodingFailed(
                    column: selectedFields[0],
                    expectedType: String(describing: Result.self)
                )
            }
        }
        throw SpectroError.notImplemented("Result type \(Result.self) must conform to TupleBuildable for multi-field selection")
    }
}

// MARK: - QueryBuilder

@dynamicMemberLookup
public struct QueryBuilder<T: Schema>: Sendable {
    public init() {}

    public subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> QueryField<V> {
        QueryField<V>(name: T.column(for: keyPath), tableName: T.tableName)
    }

    /// Refer to a joined table's columns, by its alias or, without one, its table name.
    ///
    /// ```swift
    /// repo.query(Post.self)
    ///     .join(User.self) { $0.left.userId == $0.right.id }
    ///     .where { $0.table(User.self).name == "Ana" }
    /// ```
    public func table<Model: Schema>(_ type: Model.Type, as alias: String? = nil) -> JoinQueryField<Model> {
        JoinQueryField<Model>(tableName: alias ?? Model.tableName)
    }
}

// MARK: - QueryField

public struct QueryField<V>: Sendable {
    // Preserve the database name for decoding; SQL also needs the owning table.
    let name: String
    let tableName: String
    private var binaryCollation = false

    init(name: String, tableName: String) {
        self.name = name
        self.tableName = tableName
    }

    // Qualify immediately so filters and ordering also work when a join is added later.
    var qualifiedName: String {
        let column = "\(tableName.quoted).\(name.quoted)"
        return binaryCollation ? "(\(column) COLLATE \"C\")" : column
    }

    fileprivate func withBinaryCollation() -> Self {
        var field = self
        field.binaryCollation = true
        return field
    }
}

extension QueryField where V == String {
    /// Compare exact bytes using PostgreSQL's C collation, independently of the column's locale.
    /// With a UTF-8 database, ordering is lexicographic UTF-8 order. No Unicode normalization occurs.
    public func binaryCollated() -> Self { withBinaryCollation() }
}

extension QueryField where V == String? {
    /// The nullable form of `QueryField<String>.binaryCollated()`. NULL semantics are unchanged.
    public func binaryCollated() -> Self { withBinaryCollation() }
}

// MARK: - QueryCondition
//
// SQL uses `?` as a positional sentinel — never $N.
// Column names are quoted at the point of operator use below.
// Placeholders are numbered once at query assembly time.

public struct QueryCondition: Sendable {
    let sql: String
    let parameters: [PostgresData]
    let referencedTables: Set<JoinTableReference>

    init(sql: String, parameters: [PostgresData] = [], referencedTables: Set<JoinTableReference> = []) {
        self.sql = sql
        self.parameters = parameters
        self.referencedTables = referencedTables
    }
}

// MARK: - QueryField Operators

extension QueryField where V: Equatable {
    public static func == (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) = ?", parameters: [convertToPostgresData(rhs)])
    }

    public static func != (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) != ?", parameters: [convertToPostgresData(rhs)])
    }
}

extension QueryField where V: Comparable {
    public static func > (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) > ?", parameters: [convertToPostgresData(rhs)])
    }

    public static func >= (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) >= ?", parameters: [convertToPostgresData(rhs)])
    }

    public static func < (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) < ?", parameters: [convertToPostgresData(rhs)])
    }

    public static func <= (lhs: QueryField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) <= ?", parameters: [convertToPostgresData(rhs)])
    }
}

extension QueryField where V == String {
    public func like(_ pattern: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) LIKE ?", parameters: [PostgresData(string: pattern)])
    }

    public func ilike(_ pattern: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) ILIKE ?", parameters: [PostgresData(string: pattern)])
    }

    public func notLike(_ pattern: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) NOT LIKE ?", parameters: [PostgresData(string: pattern)])
    }

    public func notIlike(_ pattern: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) NOT ILIKE ?", parameters: [PostgresData(string: pattern)])
    }

    public func startsWith(_ prefix: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) LIKE ?", parameters: [PostgresData(string: "\(prefix)%")])
    }

    public func endsWith(_ suffix: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) LIKE ?", parameters: [PostgresData(string: "%\(suffix)")])
    }

    public func contains(_ substring: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) LIKE ?", parameters: [PostgresData(string: "%\(substring)%")])
    }

    public func iStartsWith(_ prefix: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) ILIKE ?", parameters: [PostgresData(string: "\(prefix)%")])
    }

    public func iEndsWith(_ suffix: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) ILIKE ?", parameters: [PostgresData(string: "%\(suffix)")])
    }

    public func iContains(_ substring: String) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) ILIKE ?", parameters: [PostgresData(string: "%\(substring)%")])
    }
}

extension QueryField where V: Equatable {
    public func `in`<S: Sequence>(_ values: S) -> QueryCondition where S.Element == V {
        let valueArray = Array(values)
        guard !valueArray.isEmpty else {
            return QueryCondition(sql: "FALSE", parameters: [])
        }
        let placeholders = Array(repeating: "?", count: valueArray.count).joined(separator: ", ")
        return QueryCondition(
            sql: "\(qualifiedName) IN (\(placeholders))",
            parameters: valueArray.map { convertToPostgresData($0) }
        )
    }

    public func notIn<S: Sequence>(_ values: S) -> QueryCondition where S.Element == V {
        let valueArray = Array(values)
        guard !valueArray.isEmpty else {
            return QueryCondition(sql: "TRUE", parameters: [])
        }
        let placeholders = Array(repeating: "?", count: valueArray.count).joined(separator: ", ")
        return QueryCondition(
            sql: "\(qualifiedName) NOT IN (\(placeholders))",
            parameters: valueArray.map { convertToPostgresData($0) }
        )
    }
}

extension QueryField where V: Comparable {
    public func between(_ lower: V, and upper: V) -> QueryCondition {
        QueryCondition(
            sql: "\(qualifiedName) BETWEEN ? AND ?",
            parameters: [convertToPostgresData(lower), convertToPostgresData(upper)]
        )
    }
}

extension QueryField where V == Date {
    public func before(_ date: Date) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) < ?", parameters: [PostgresData(date: date)])
    }

    public func after(_ date: Date) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) > ?", parameters: [PostgresData(date: date)])
    }

    public func isToday() -> QueryCondition {
        QueryCondition(sql: "DATE(\(qualifiedName)) = CURRENT_DATE")
    }

    public func isThisWeek() -> QueryCondition {
        QueryCondition(sql: "DATE_TRUNC('week', \(qualifiedName)) = DATE_TRUNC('week', CURRENT_DATE)")
    }

    public func isThisMonth() -> QueryCondition {
        QueryCondition(sql: "DATE_TRUNC('month', \(qualifiedName)) = DATE_TRUNC('month', CURRENT_DATE)")
    }

    public func isThisYear() -> QueryCondition {
        QueryCondition(sql: "DATE_TRUNC('year', \(qualifiedName)) = DATE_TRUNC('year', CURRENT_DATE)")
    }
}

// MARK: - Array Operators

extension QueryField {
    /// `element = ANY(column)`: the array column contains `element`.
    public func contains<E: DatabaseValue>(_ element: E) -> QueryCondition where V == [E] {
        QueryCondition(sql: "? = ANY(\(qualifiedName))", parameters: [convertToPostgresData(element)])
    }

    /// `column @> elements`: the array column contains every one of `elements`.
    public func containsAll<E: DatabaseValue>(_ elements: [E]) -> QueryCondition where V == [E] {
        QueryCondition(sql: "\(qualifiedName) @> ?", parameters: [convertToPostgresData(elements)])
    }

    /// `column && elements`: the array column shares at least one element with `elements`.
    public func overlaps<E: DatabaseValue>(_ elements: [E]) -> QueryCondition where V == [E] {
        QueryCondition(sql: "\(qualifiedName) && ?", parameters: [convertToPostgresData(elements)])
    }

    /// The nullable form of `contains(_:)`. A NULL array contains nothing.
    public func contains<E: DatabaseValue>(_ element: E) -> QueryCondition where V == [E]? {
        QueryCondition(sql: "? = ANY(\(qualifiedName))", parameters: [convertToPostgresData(element)])
    }

    /// The nullable form of `containsAll(_:)`.
    public func containsAll<E: DatabaseValue>(_ elements: [E]) -> QueryCondition where V == [E]? {
        QueryCondition(sql: "\(qualifiedName) @> ?", parameters: [convertToPostgresData(elements)])
    }

    /// The nullable form of `overlaps(_:)`.
    public func overlaps<E: DatabaseValue>(_ elements: [E]) -> QueryCondition where V == [E]? {
        QueryCondition(sql: "\(qualifiedName) && ?", parameters: [convertToPostgresData(elements)])
    }
}

extension QueryField {
    public func isNull() -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) IS NULL")
    }

    public func isNotNull() -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) IS NOT NULL")
    }
}


// MARK: - Logical Operators

public func && (lhs: QueryCondition, rhs: QueryCondition) -> QueryCondition {
    QueryCondition(
        sql: "(\(lhs.sql)) AND (\(rhs.sql))",
        parameters: lhs.parameters + rhs.parameters,
        referencedTables: lhs.referencedTables.union(rhs.referencedTables)
    )
}

public func || (lhs: QueryCondition, rhs: QueryCondition) -> QueryCondition {
    QueryCondition(
        sql: "(\(lhs.sql)) OR (\(rhs.sql))",
        parameters: lhs.parameters + rhs.parameters,
        referencedTables: lhs.referencedTables.union(rhs.referencedTables)
    )
}

public prefix func ! (condition: QueryCondition) -> QueryCondition {
    QueryCondition(sql: "NOT (\(condition.sql))", parameters: condition.parameters, referencedTables: condition.referencedTables)
}

// MARK: - PostgresData Conversion

func convertToPostgresData(_ value: Any) -> PostgresData {
    if let v = value as? any DatabaseValue, let data = try? v.toPostgresData() { return data }
    return PostgresData(string: "\(value)")
}

// MARK: - Supporting Types

internal struct OrderByClause: Sendable {
    let field: String
    let direction: OrderDirection
}

internal struct JoinTableReference: Hashable, Sendable {
    let identifier: String
    let table: String
}

internal struct JoinClause: Sendable {
    let type: JoinType
    let table: String
    let alias: String?
    let softDeleteColumn: String?
    let condition: String
    let parameters: [PostgresData]
    let referencedTables: Set<JoinTableReference>

    var identifier: String { alias ?? table }

    init(type: JoinType, table: String, alias: String? = nil, softDeleteColumn: String?, condition: String, parameters: [PostgresData], referencedTables: Set<JoinTableReference> = []) {
        self.type = type
        self.table = table
        self.alias = alias
        self.softDeleteColumn = softDeleteColumn
        self.condition = condition
        self.parameters = parameters
        self.referencedTables = referencedTables
    }
}

internal enum JoinType: Sendable {
    case inner, left, right, full

    var sql: String {
        switch self {
        case .inner: return "INNER JOIN"
        case .left: return "LEFT JOIN"
        case .right: return "RIGHT JOIN"
        case .full: return "FULL OUTER JOIN"
        }
    }
}

// MARK: - Join Builders

@dynamicMemberLookup
public struct JoinBuilder<T: Schema, U: Schema>: Sendable {
    public init() { self.rightTableName = U.tableName }

    private let rightTableName: String

    internal init(rightTableName: String) { self.rightTableName = rightTableName }

    public var left: JoinQueryField<T> { JoinQueryField<T>(tableName: T.tableName) }
    public var right: JoinQueryField<U> { JoinQueryField<U>(tableName: rightTableName) }

    /// Refer to a table already present in the query while building another join.
    public func table<Model: Schema>(_ type: Model.Type, as alias: String) -> JoinQueryField<Model> {
        JoinQueryField<Model>(tableName: alias)
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> JoinField<V> {
        JoinField<V>(tableName: T.tableName, fieldName: T.column(for: keyPath), schemaTable: T.tableName)
    }
}

public struct ThroughJoinBuilder<T: Schema, U: Schema, Junction: Schema>: Sendable {
    public init() {}

    public var main: JoinQueryField<T> { JoinQueryField<T>(tableName: T.tableName) }
    public var junction: JoinQueryField<Junction> { JoinQueryField<Junction>(tableName: Junction.tableName) }
    public var target: JoinQueryField<U> { JoinQueryField<U>(tableName: U.tableName) }
}

@dynamicMemberLookup
public struct JoinQueryField<T: Schema>: Sendable {
    let tableName: String

    init(tableName: String) {
        self.tableName = tableName
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> JoinField<V> {
        JoinField<V>(tableName: tableName, fieldName: T.column(for: keyPath), schemaTable: T.tableName)
    }
}

public struct JoinField<V>: Sendable {
    let tableName: String
    let fieldName: String
    let schemaTable: String

    init(tableName: String, fieldName: String, schemaTable: String) {
        self.tableName = tableName
        self.fieldName = fieldName
        self.schemaTable = schemaTable
    }

    internal var tableReference: JoinTableReference {
        JoinTableReference(identifier: tableName, table: schemaTable)
    }

    /// Fully-qualified, quoted identifier: `"table"."column"`
    var qualifiedName: String {
        "\(tableName.quoted).\(fieldName.quoted)"
    }
}

// MARK: - JoinField Operators

extension JoinField where V: Equatable {
    public static func == (lhs: JoinField<V>, rhs: JoinField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
    }

    public static func == (lhs: JoinField<V>, rhs: V) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) = ?", parameters: [convertToPostgresData(rhs)], referencedTables: [lhs.tableReference])
    }

    public static func != (lhs: JoinField<V>, rhs: JoinField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) != \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
    }
}

extension JoinField where V: Comparable {
    public static func > (lhs: JoinField<V>, rhs: JoinField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) > \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
    }

    public static func < (lhs: JoinField<V>, rhs: JoinField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) < \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
    }
}

/// SQL permits comparing a nullable foreign key with a nonnullable primary key.
public func == <Value: Equatable>(lhs: JoinField<Value?>, rhs: JoinField<Value>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
}

public func == <Value: Equatable>(lhs: JoinField<Value>, rhs: JoinField<Value?>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)", referencedTables: [lhs.tableReference, rhs.tableReference])
}

// MARK: - KeyPath Field Name Extraction

internal func extractFieldName<T: Schema, V>(from keyPath: KeyPath<T, V>, schema: T.Type) -> String {
    if let name = T._keyPathToColumn[keyPath] { return name }
    let keyPathString = "\(keyPath)"
    return keyPathString.components(separatedBy: ".").last ?? keyPathString
}
