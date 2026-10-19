import Foundation
import PostgresNIO

/// The SQL and bind values produced by a query's `all()` operation.
///
/// Values are kept separate from SQL. Avoid logging `parameters` if they may
/// contain private data.
public struct QueryStatement: Sendable {
    public let sql: String
    public let parameters: [PostgresData]

    internal init(sql: String, parameters: [PostgresData]) {
        self.sql = sql
        self.parameters = parameters
    }
}

/// Rows returned by an opt-in timed query execution.
public struct TimedQueryResult<Row: Sendable>: Sendable {
    public let rows: [Row]
    public let duration: Duration

    internal init(rows: [Row], duration: Duration) {
        self.rows = rows
        self.duration = duration
    }
}

private func executeExplain(
    _ statement: QueryStatement,
    using executor: any QueryExecutor
) async throws -> [String] {
    try await executor.executeQuery(
        sql: "EXPLAIN \(statement.sql)",
        parameters: statement.parameters,
        resultMapper: { row in
            guard let line = row.makeRandomAccess()[data: "QUERY PLAN"].string else {
                throw SpectroError.resultDecodingFailed(column: "QUERY PLAN", expectedType: "String")
            }
            return line
        }
    )
}

private func measureRows<Row: Sendable>(
    _ operation: () async throws -> [Row]
) async throws -> TimedQueryResult<Row> {
    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await operation()
    return TimedQueryResult(rows: rows, duration: start.duration(to: clock.now))
}

extension Query {
    /// Render the SELECT performed by `all()` without executing it.
    public func statement() throws -> QueryStatement {
        try validateJoins()
        guard !joins.contains(where: { $0.type == .right }) else {
            throw SpectroError.invalidSchema(reason: "A right join can have an absent main row and cannot return nonoptional models. Reverse the query and use a left join.")
        }
        return QueryStatement(sql: buildSQL(), parameters: parameters)
    }

    /// Ask PostgreSQL for the SELECT plan without executing the SELECT.
    /// This uses plain `EXPLAIN` and never enables `ANALYZE`.
    public func explain() async throws -> [String] {
        try await executeExplain(statement(), using: executor)
    }

    /// Execute `all()` and report wall-clock time including row decoding.
    public func timedAll() async throws -> TimedQueryResult<T> {
        try await measureRows { try await all() }
    }
}

extension TupleQuery {
    /// Render the projected SELECT performed by `all()` without executing it.
    public func statement() throws -> QueryStatement {
        let context = try inspectionContext()
        return QueryStatement(sql: context.sql, parameters: context.parameters)
    }

    /// Ask PostgreSQL for the projected SELECT plan without executing the SELECT.
    public func explain() async throws -> [String] {
        let context = try inspectionContext()
        return try await executeExplain(QueryStatement(sql: context.sql, parameters: context.parameters), using: context.executor)
    }

    /// Execute `all()` and report wall-clock time including row decoding.
    public func timedAll() async throws -> TimedQueryResult<Result> {
        try await measureRows { try await all() }
    }
}

extension JoinQuery {
    /// Render the typed-join SELECT performed by `all()` without executing it.
    public func statement() throws -> QueryStatement {
        let context = try inspectionContext()
        return QueryStatement(sql: context.sql, parameters: context.parameters)
    }

    /// Ask PostgreSQL for the typed-join SELECT plan without executing the SELECT.
    public func explain() async throws -> [String] {
        let context = try inspectionContext()
        return try await executeExplain(QueryStatement(sql: context.sql, parameters: context.parameters), using: context.executor)
    }

    /// Execute `all()` and report wall-clock time including row decoding.
    public func timedAll() async throws -> TimedQueryResult<(T, U?)> {
        try await measureRows { try await all() }
    }
}
