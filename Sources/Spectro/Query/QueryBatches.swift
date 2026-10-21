import Foundation
import PostgresNIO

extension Query {
    /// The query's rows in batches of `size`, in primary key order, so a large result never
    /// sits in memory at once, like Ecto's `Repo.stream`.
    ///
    /// ```swift
    /// let active = repo.query(User.self).where { $0.isActive == true }
    /// for try await users in active.batches(of: 1000) {
    ///     try await mailer.send(to: users)
    /// }
    /// ```
    ///
    /// Each batch is one query that resumes after the previous batch's last key, so a row
    /// written meanwhile may or may not appear. A row a join repeats appears once. Iterate in a `repeatableRead` transaction to read
    /// one snapshot. The query must not have ordering, a limit, an offset, or `distinct(_:)`.
    public func batches(of size: Int = 500) -> QueryBatches<T> {
        QueryBatches(query: self, size: size)
    }
}

/// The batches of `Query.batches(of:)`.
public struct QueryBatches<T: Schema>: AsyncSequence, Sendable {
    public typealias Element = [T]

    let query: Query<T>
    let size: Int

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(query: query, size: size)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let query: Query<T>
        let size: Int
        var lastKey: PostgresData?
        var finished = false

        public mutating func next() async throws -> [T]? {
            guard !finished else { return nil }
            guard size > 0, query.orderFields.isEmpty, query.limitValue == nil, query.offsetValue == nil,
                  query.distinctColumns?.isEmpty ?? true else {
                throw SpectroError.invalidQuery("batches(of:) needs a positive size and a query without ordering, limit, offset, or distinct(_:)")
            }
            let metadata = await SchemaRegistry.shared.register(T.self)
            guard let key = metadata.fields.first(where: \.isPrimaryKey) else {
                throw SpectroError.invalidSchema(reason: "Schema \(T.self) has no primary key field")
            }
            let column = query.qualifiedColumn(key.databaseName)
            var page = query
            if let lastKey {
                page = page.where { _ in QueryCondition(sql: "\(column) > ?", parameters: [lastKey]) }
            }
            page.orderFields = [OrderByClause(field: column, direction: .asc)]
            page.limitValue = size
            // A join can repeat a row, which the keyset would cut between batches: keep one per key.
            if !page.joins.isEmpty && page.distinctColumns == nil { page.distinctColumns = [column] }
            page.selectedFields?.insert(key.databaseName)

            let rows = try await page.all()
            finished = rows.count < size
            guard let last = rows.last else { return nil }
            guard let next = PreloadQuery<T>.extractPrimaryKeyPair(from: last, fieldName: key.name)?.data else {
                throw SpectroError.invalidSchema(reason: "Could not extract primary key value from \(T.self)")
            }
            lastKey = next
            return rows
        }
    }
}
