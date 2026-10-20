import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import PostgresNIO

/// One SQL statement Spectro ran, reported to `DatabaseConfiguration.onQuery`, like the
/// telemetry event Ecto emits for each query.
public struct QueryEvent: Sendable {
    /// The statement, with `$1`-style placeholders.
    public let sql: String
    /// The bound values. Avoid recording them if they may contain private data.
    public let parameters: [PostgresData]
    /// Time from sending the statement to receiving all rows, before decoding into models.
    public let queryTime: Duration
    /// Time spent waiting for a pooled connection, or `nil` on a transaction's own connection.
    public let queueTime: Duration?
    /// The number of rows returned. Zero for a failed statement.
    public let rowCount: Int
    /// Whether the statement ran on a transaction's connection, including `BEGIN` and `COMMIT`.
    public let inTransaction: Bool
    /// The error the statement failed with, or `nil` on success.
    public let error: (any Error)?
}

/// Receives a `QueryEvent` for each statement. It runs on a connection's event loop, so keep it fast.
public typealias QueryObserver = @Sendable (QueryEvent) -> Void

/// Reports statements to the configured logger and observer.
struct QueryInstrumentation: Sendable {
    let logger: Logger?
    let observer: QueryObserver?

    var isEnabled: Bool { logger != nil || observer != nil }

    /// Report `future`'s statement when it completes, timing it from `started`.
    func observe<T>(
        _ future: EventLoopFuture<T>,
        sql: String,
        parameters: [PostgresData],
        queued: Duration?,
        started: ContinuousClock.Instant,
        inTransaction: Bool,
        rowCount: @escaping @Sendable (T) -> Int
    ) -> EventLoopFuture<T> {
        guard isEnabled else { return future }
        return future.always { result in
            let event: QueryEvent
            switch result {
            case .success(let value):
                event = QueryEvent(sql: sql, parameters: parameters, queryTime: started.duration(to: .now), queueTime: queued,
                                   rowCount: rowCount(value), inTransaction: inTransaction, error: nil)
            case .failure(let error):
                event = QueryEvent(sql: sql, parameters: parameters, queryTime: started.duration(to: .now), queueTime: queued,
                                   rowCount: 0, inTransaction: inTransaction, error: error)
            }
            report(event)
        }
    }

    private func report(_ event: QueryEvent) {
        if let logger {
            var metadata: Logger.Metadata = [
                "db_ms": "\(Self.milliseconds(event.queryTime))",
                "rows": "\(event.rowCount)",
                "params": "\(event.parameters.count)",
            ]
            if let queued = event.queueTime { metadata["queue_ms"] = "\(Self.milliseconds(queued))" }
            if event.inTransaction { metadata["transaction"] = "true" }
            if let error = event.error { metadata["error"] = "\(String(reflecting: error))" }
            logger.debug("\(event.error == nil ? "QUERY OK" : "QUERY ERROR") \(event.sql)", metadata: metadata)
        }
        observer?(event)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}
