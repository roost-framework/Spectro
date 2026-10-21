/// The isolation level of a transaction, as PostgreSQL defines it.
public enum TransactionIsolation: Sendable {
    /// Each statement sees the data committed before it began. PostgreSQL's default.
    case readCommitted
    /// Every statement sees the data committed before the transaction's first statement. Updating
    /// a row another transaction changed since then fails with SQLSTATE `40001`.
    case repeatableRead
    /// Like `repeatableRead`, and committed transactions have the effect of running one at a time.
    /// A transaction that could break that fails with SQLSTATE `40001`; run it again.
    case serializable

    var sql: String {
        switch self {
        case .readCommitted: "READ COMMITTED"
        case .repeatableRead: "REPEATABLE READ"
        case .serializable: "SERIALIZABLE"
        }
    }
}
