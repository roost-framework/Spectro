import Foundation
import PostgresNIO

/// An error reported by the PostgreSQL server, read from either PostgresNIO error type.
public struct DatabaseServerError: Sendable, Equatable {
    /// The SQLSTATE code, such as `23505` for a unique violation.
    public let sqlState: String
    /// The primary error message.
    public let message: String
    /// The constraint or index the error concerns, if any.
    public let constraintName: String?
    /// The secondary message with more detail, if any.
    public let detail: String?
    /// The table the error concerns, if any.
    public let tableName: String?
    /// The column the error concerns, if any.
    public let columnName: String?

    public init(
        sqlState: String,
        message: String,
        constraintName: String? = nil,
        detail: String? = nil,
        tableName: String? = nil,
        columnName: String? = nil
    ) {
        self.sqlState = sqlState
        self.message = message
        self.constraintName = constraintName
        self.detail = detail
        self.tableName = tableName
        self.columnName = columnName
    }
}

extension SpectroError {
    /// The PostgreSQL server error behind this error, or `nil` if the server reported none.
    ///
    /// Unwraps `transactionFailed`, the original error of `transactionAndRollbackFailed`,
    /// `changesetFailed`, `queryExecutionFailed`, `invalidSql`, `migrationFailed`, and `connectionFailed`, including
    /// nested `SpectroError`s, then reads PostgresNIO's `PSQLError` or its legacy
    /// `PostgresError.server`. Errors Spectro raises itself, such as `notFound`, and connection
    /// failures without a server response return `nil`.
    public var serverError: DatabaseServerError? {
        DatabaseServerError(from: self)
    }

    /// The error this case wraps, where a server error may be found.
    fileprivate var wrappedError: (any Error)? {
        switch self {
        case .transactionFailed(let error),
             .transactionAndRollbackFailed(let error, _),
             .queryExecutionFailed(_, let error),
             .invalidSql(_, let error),
             .migrationFailed(_, let error),
             .connectionFailed(let error):
            return error
        case .changesetFailed(_, let underlying):
            return underlying
        default:
            return nil
        }
    }
}

extension DatabaseServerError {
    fileprivate init?(from error: any Error) {
        switch error {
        case let error as SpectroError:
            guard let wrapped = error.wrappedError, let found = DatabaseServerError(from: wrapped) else { return nil }
            self = found
        case let error as PSQLError:
            guard let info = error.serverInfo, let sqlState = info[.sqlState] else { return nil }
            self.init(
                sqlState: sqlState,
                message: info[.message] ?? "",
                constraintName: info[.constraintName],
                detail: info[.detail],
                tableName: info[.tableName],
                columnName: info[.columnName]
            )
        case let error as PostgresError:
            guard case .server(let response) = error, let sqlState = response.fields[.sqlState] else { return nil }
            self.init(
                sqlState: sqlState,
                message: response.fields[.message] ?? "",
                constraintName: response.fields[.constraintName],
                detail: response.fields[.detail],
                tableName: response.fields[.tableName],
                columnName: response.fields[.columnName]
            )
        default:
            return nil
        }
    }
}
