import Foundation
import PostgresNIO

/// Rows a query selects from in place of its table, under the table's name.
struct QuerySource: Sendable {
    /// A SELECT with `?` placeholders.
    let sql: String
    let parameters: [PostgresData]
    /// A failed validation of the queries composed into `sql`, thrown when the query runs.
    var error: (any Error)?
}

// MARK: - Distinct

extension Query {
    /// Remove duplicate rows, such as those a join repeats: `SELECT DISTINCT`.
    public func distinct() -> Query<T> {
        var copy = self
        copy.distinctColumns = distinctColumns ?? []
        return copy
    }

    /// Keep the first row of each distinct value of `field`, in the query's order: `SELECT DISTINCT ON`.
    /// Call it again to add columns.
    ///
    /// ```swift
    /// // Each author's latest post
    /// let latest = try await repo.query(Post.self)
    ///     .distinct { $0.authorId }
    ///     .orderBy({ $0.createdAt }, .desc)
    ///     .all()
    /// ```
    ///
    /// PostgreSQL needs the DISTINCT ON columns first in ORDER BY, so those the ordering does
    /// not start with are sorted first, in ascending order, as Ecto does. `count()` and
    /// aggregates see each remaining row once.
    public func distinct<V>(_ field: (QueryBuilder<T>) -> QueryField<V>) -> Query<T> {
        var copy = self
        copy.distinctColumns = (distinctColumns ?? []) + [field(QueryBuilder<T>()).qualifiedName]
        return copy
    }

    /// The rows the query selects, ignoring limit, offset, and lock as counts do, as the source
    /// of a query that aggregates them. Only DISTINCT ON needs the ordering, to choose its rows.
    /// The groups of a grouped query keep its ordering, limit, and offset.
    func distinctRows(grouped: Bool = false) -> Query<T> {
        var rows = self
        rows.limitValue = nil
        rows.offsetValue = nil
        rows.lockClause = nil
        if distinctColumns?.isEmpty == true { rows.orderFields = [] }
        var outer = Query(schema: T.self, executor: executor)
        outer.source = QuerySource(sql: rows.selectSQL(), parameters: rows.parameters)
        outer.groupByFields = groupByFields
        outer.havingClause = havingClause
        outer.havingParameters = havingParameters
        if grouped {
            outer.orderFields = orderFields
            outer.limitValue = limitValue
            outer.offsetValue = offsetValue
        }
        return outer
    }
}

// MARK: - Set Operations

extension Query {
    /// The rows of this query or `other`, without duplicates: `UNION`, like Ecto's `union`.
    ///
    /// ```swift
    /// let feed = try await repo.query(Post.self).where { $0.authorId == me }
    ///     .union(repo.query(Post.self).where { $0.pinned == true })
    ///     .orderBy({ $0.createdAt }, .desc)
    ///     .limit(20)
    ///     .all()
    /// ```
    ///
    /// Each query keeps its own filters, joins, ordering, and limit. Clauses added to the
    /// result apply to the combined rows. Both queries must select whole rows.
    public func union(_ other: Query<T>) -> Query<T> { combined("UNION", other) }

    /// The rows of this query and `other`, with duplicates: `UNION ALL`.
    public func unionAll(_ other: Query<T>) -> Query<T> { combined("UNION ALL", other) }

    /// The rows of this query that `other` also selects: `INTERSECT`.
    public func intersect(_ other: Query<T>) -> Query<T> { combined("INTERSECT", other) }

    /// `INTERSECT ALL`, which keeps duplicates.
    public func intersectAll(_ other: Query<T>) -> Query<T> { combined("INTERSECT ALL", other) }

    /// The rows of this query that `other` does not select: `EXCEPT`.
    public func except(_ other: Query<T>) -> Query<T> { combined("EXCEPT", other) }

    /// `EXCEPT ALL`, which keeps duplicates.
    public func exceptAll(_ other: Query<T>) -> Query<T> { combined("EXCEPT ALL", other) }

    private func combined(_ operation: String, _ other: Query<T>) -> Query<T> {
        composed(
            sql: "(\(selectSQL())) \(operation) (\(other.selectSQL()))",
            parameters: parameters + other.parameters,
            validating: [self, other]
        )
    }

    /// A query over rows composed from `queries`, under the table's name.
    private func composed(sql: String, parameters: [PostgresData], validating queries: [Query<T>]) -> Query<T> {
        var result = Query(schema: T.self, executor: executor)
        result.source = QuerySource(sql: sql, parameters: parameters)
        do {
            for query in queries {
                try query.validateJoins()
                guard query.lockClause == nil else {
                    throw SpectroError.invalidQuery("PostgreSQL cannot lock the rows of a set operation or a recursive query")
                }
                guard query.selectedFields == nil else {
                    throw SpectroError.invalidQuery("Set operations and recursive queries combine whole rows; remove selectFields")
                }
            }
        } catch {
            result.source?.error = error
        }
        return result
    }
}

// MARK: - Recursion

extension Query {
    /// The query's rows and, repeatedly, the rows `step` reaches from rows already found:
    /// `WITH RECURSIVE`. In `step`, `$0.left` is a row of the table and `$0.right` a row found.
    ///
    /// ```swift
    /// // A category and all its descendants
    /// let subtree = try await repo.query(Category.self)
    ///     .where { $0.id == rootID }
    ///     .recursive { $0.left.parentId == $0.right.id }
    ///     .orderBy { $0.name }
    ///     .all()
    ///
    /// // Its ancestors
    /// .recursive { $0.left.id == $0.right.parentId }
    /// ```
    ///
    /// A row found again is not followed again, so cycles end. Soft-deleted rows are not
    /// reached unless the query uses `withDeleted()`. Clauses added to the result apply to
    /// every row found.
    public func recursive(_ step: (JoinBuilder<T, T>) -> QueryCondition) -> Query<T> {
        let found = "spectro_recursive".quoted
        let table = T.tableName.quoted
        let condition = step(JoinBuilder<T, T>(rightTableName: "spectro_recursive"))
        var next = "SELECT \(table).* FROM \(table) INNER JOIN \(found) ON \(condition.sql)"
        if let column = T.softDeleteColumn, !includeSoftDeleted {
            next += " WHERE \(table).\(column.quoted) IS NULL"
        }
        return composed(
            sql: "WITH RECURSIVE \(found) AS ((\(selectSQL())) UNION \(next)) SELECT * FROM \(found)",
            parameters: parameters + condition.parameters,
            validating: [self]
        )
    }
}

// MARK: - Lateral Joins

extension Query {
    /// Join the rows `subquery` selects for each row: `INNER JOIN LATERAL`, like Ecto's
    /// lateral joins. The subquery refers to the row through the builder's fields.
    ///
    /// ```swift
    /// // Each author with their three most viewed posts
    /// let top = try await repo.query(Author.self)
    ///     .joinLateral { author in
    ///         repo.query(Post.self).where { $0.authorId == author.id }.orderBy({ $0.views }, .desc).limit(3)
    ///     }
    ///     .executeJoin(with: Post.self)
    ///     .all()
    /// ```
    ///
    /// The joined rows go by the subquery's table name, or by `alias`, in filters, ordering,
    /// and `executeJoin(with:as:)`. The subquery keeps its own soft-delete filter; call
    /// `withDeleted()` on it to include deleted rows. It cannot lock rows. As with
    /// `exists(_:)`, a subquery of the queried table itself cannot refer to the outer row.
    public func joinLateral<U: Schema>(as alias: String? = nil, _ subquery: (QueryBuilder<T>) -> Query<U>) -> Query<T> {
        lateral(.inner, alias: alias, subquery)
    }

    /// `joinLateral(as:_:)` that keeps rows for which `subquery` selects nothing: `LEFT JOIN LATERAL`.
    public func leftJoinLateral<U: Schema>(as alias: String? = nil, _ subquery: (QueryBuilder<T>) -> Query<U>) -> Query<T> {
        lateral(.left, alias: alias, subquery)
    }

    private func lateral<U: Schema>(_ type: JoinType, alias: String?, _ subquery: (QueryBuilder<T>) -> Query<U>) -> Query<T> {
        let rows = subquery(QueryBuilder<T>())
        var source = QuerySource(sql: rows.selectSQL(), parameters: rows.parameters)
        do {
            try rows.validateJoins()
            // Counts and aggregates drop the outer query's lock, but could not drop this one.
            guard rows.lockClause == nil else { throw SpectroError.invalidQuery("A lateral subquery cannot lock rows") }
        } catch {
            source.error = error
        }
        var copy = self
        copy.joins.append(JoinClause(
            type: type, table: U.tableName, alias: alias, softDeleteColumn: nil,
            condition: "TRUE", parameters: source.parameters, source: source
        ))
        return copy
    }
}

// MARK: - Window Filters

extension Query {
    /// Keep the rows for which `condition` holds, a condition that may use window functions,
    /// as SQL's `QUALIFY` does, which PostgreSQL lacks. Fields become qualified columns and
    /// values bound parameters, as in `SQLFragment`.
    ///
    /// ```swift
    /// // The two most viewed posts of each author
    /// let top = try await repo.query(Post.self)
    ///     .qualify { "row_number() OVER (PARTITION BY \($0.authorId) ORDER BY \($0.views) DESC) <= \(2)" }
    ///     .orderBy { $0.title }
    ///     .all()
    /// ```
    ///
    /// The window functions see the rows the query selects so far, after its filters, joins,
    /// distinct, ordering, and limit. Clauses added to the result apply to the remaining rows,
    /// so add ordering and limits after it.
    public func qualify(_ condition: (QueryBuilder<T>) -> SQLFragment) -> Query<T> {
        let fragment = condition(QueryBuilder<T>())
        let table = T.tableName.quoted
        let columns = SchemaRegistry.extractMetadata(from: T.self).fields.map(\.databaseName.quoted).joined(separator: ", ")
        // PostgreSQL computes window functions before DISTINCT and LIMIT, so compute them over
        // the rows those select; without them, the condition may also refer to joined tables.
        var rows = self
        if distinctColumns != nil || limitValue != nil || offsetValue != nil {
            rows = Query(schema: T.self, executor: executor)
            rows.source = QuerySource(sql: selectSQL(), parameters: parameters)
        }
        let ranked = rows.selectSQL(selectClause: "\(table).*, (\(fragment.sql)) AS \"spectro_qualify\"")
        return composed(
            sql: "SELECT \(columns) FROM (\(ranked)) AS \(table) WHERE \"spectro_qualify\"",
            parameters: fragment.parameters + rows.parameters,
            validating: [self]
        )
    }
}

// MARK: - Existence

extension Query {
    /// Whether the query matches any row, like Ecto's `Repo.exists?`.
    public func exists() async throws -> Bool {
        try validateJoins()
        let probe = existenceProbe()
        let results = try await executor.executeQuery(
            sql: renumberPlaceholders(in: "SELECT EXISTS (\(probe.sql)) AS \"exists\""),
            parameters: probe.parameters
        ) { row in
            row.makeRandomAccess()[data: "exists"].bool ?? false
        }
        return results.first ?? false
    }

    /// The SELECT that EXISTS tests: one column without ordering, unless DISTINCT needs the rows.
    func existenceProbe() -> QuerySource {
        var rows = self
        rows.lockClause = nil
        guard distinctColumns == nil else {
            return QuerySource(sql: rows.selectSQL(), parameters: rows.parameters)
        }
        rows.orderFields = []
        return QuerySource(sql: rows.selectSQL(selectClause: "1"), parameters: rows.parameters)
    }
}

extension QueryCondition {
    /// Whether `subquery` matches any row: `EXISTS (SELECT …)`. Negate it with `!`.
    ///
    /// Refer to the outer query's fields in the subquery's filters to correlate them:
    ///
    /// ```swift
    /// let commented = try await repo.query(Post.self)
    ///     .where { post in .exists(repo.query(Comment.self).where { $0.postId == post.id }) }
    ///     .all()
    /// ```
    ///
    /// A subquery of the queried table itself cannot refer to the outer row: its own columns
    /// have the same names. Use a join with an alias instead.
    public static func exists<S: Schema>(_ subquery: Query<S>) -> QueryCondition {
        let probe = subquery.existenceProbe()
        return QueryCondition(sql: "EXISTS (\(probe.sql))", parameters: probe.parameters)
    }
}

// MARK: - Subqueries

extension QueryField {
    /// The column's value is among those `subquery` selects: `IN (SELECT …)`.
    ///
    /// ```swift
    /// let authors = try await repo.query(User.self)
    ///     .where { $0.id.in(repo.query(Post.self).where { $0.published == true }.select { $0.authorId }) }
    ///     .all()
    /// ```
    public func `in`<S: Schema>(_ subquery: TupleQuery<S, V>) -> QueryCondition {
        membership("IN", subquery.subquery)
    }

    /// `in(_:)` for a subquery selecting a nullable column.
    public func `in`<S: Schema>(_ subquery: TupleQuery<S, V?>) -> QueryCondition {
        membership("IN", subquery.subquery)
    }

    /// `in(_:)` for a nullable column.
    public func `in`<S: Schema, W>(_ subquery: TupleQuery<S, W>) -> QueryCondition where V == W? {
        membership("IN", subquery.subquery)
    }

    /// The column's value is not among those `subquery` selects: `NOT IN (SELECT …)`.
    /// As in SQL, a NULL among them makes it match no row; exclude NULLs with `isNotNull()`.
    public func notIn<S: Schema>(_ subquery: TupleQuery<S, V>) -> QueryCondition {
        membership("NOT IN", subquery.subquery)
    }

    /// `notIn(_:)` for a subquery selecting a nullable column.
    public func notIn<S: Schema>(_ subquery: TupleQuery<S, V?>) -> QueryCondition {
        membership("NOT IN", subquery.subquery)
    }

    /// `notIn(_:)` for a nullable column.
    public func notIn<S: Schema, W>(_ subquery: TupleQuery<S, W>) -> QueryCondition where V == W? {
        membership("NOT IN", subquery.subquery)
    }

    private func membership(_ operation: String, _ subquery: QuerySource) -> QueryCondition {
        QueryCondition(sql: "\(qualifiedName) \(operation) (\(subquery.sql))", parameters: subquery.parameters)
    }
}

// MARK: - Column Comparisons

extension QueryField where V: Equatable {
    /// Compare two columns of the queried table, or, in a subquery, a column with one of the
    /// outer query's table.
    public static func == (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)")
    }

    public static func != (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) != \(rhs.qualifiedName)")
    }
}

extension QueryField where V: Comparable {
    public static func > (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) > \(rhs.qualifiedName)")
    }

    public static func >= (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) >= \(rhs.qualifiedName)")
    }

    public static func < (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) < \(rhs.qualifiedName)")
    }

    public static func <= (lhs: QueryField<V>, rhs: QueryField<V>) -> QueryCondition {
        QueryCondition(sql: "\(lhs.qualifiedName) <= \(rhs.qualifiedName)")
    }
}

/// SQL permits comparing a nullable column with a nonnullable one.
public func == <Value: Equatable>(lhs: QueryField<Value?>, rhs: QueryField<Value>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)")
}

public func == <Value: Equatable>(lhs: QueryField<Value>, rhs: QueryField<Value?>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) = \(rhs.qualifiedName)")
}

public func != <Value: Equatable>(lhs: QueryField<Value?>, rhs: QueryField<Value>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) != \(rhs.qualifiedName)")
}

public func != <Value: Equatable>(lhs: QueryField<Value>, rhs: QueryField<Value?>) -> QueryCondition {
    QueryCondition(sql: "\(lhs.qualifiedName) != \(rhs.qualifiedName)")
}
