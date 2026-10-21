import Foundation

/// Comprehensive error system for Spectro ORM
public enum SpectroError: Error, Sendable {
    // MARK: - Connection
    case connectionFailed(underlying: any Error & Sendable)
    case connectionPoolExhausted
    case invalidConnectionConfiguration(String)

    // MARK: - Query
    case invalidQuery(String)
    case invalidSql(sql: String, error: any Error & Sendable)
    /// `value` is the pre-formatted string description of the invalid parameter value.
    case invalidParameter(name: String, value: String?, reason: String? = nil)
    case queryExecutionFailed(sql: String, error: any Error & Sendable)
    case resultDecodingFailed(column: String, expectedType: String)

    // MARK: - Data
    case notFound(schema: String, id: String)
    /// An update guarded by `Changeset.optimisticLock(_:)` found the record changed or deleted
    /// since it was loaded, like Ecto's `Ecto.StaleEntryError`.
    case staleRecord(schema: String, id: String)
    case unexpectedResultCount(expected: Int, actual: Int)
    /// `value` is the pre-formatted string description of the invalid field value.
    case invalidData(field: String, value: String?, reason: String)
    case validationError(field: String, errors: [String])
    /// Structured field errors from a declared database constraint. The original write error
    /// remains available through `underlying` and `serverError`.
    case changesetFailed(errors: ChangesetErrors, underlying: any Error & Sendable)
    case constraintViolation(String)
    case databaseError(reason: String)

    // MARK: - Schema
    case invalidSchema(reason: String)
    case invalidField(schema: String, field: String)
    case relationshipError(from: String, to: String, reason: String)
    case relationshipNotFound(relationship: String, schema: String)
    case missingRequiredField(String)

    // MARK: - Transaction
    case transactionFailed(underlying: any Error & Sendable)
    case transactionAndRollbackFailed(original: any Error & Sendable, rollback: any Error & Sendable)
    case transactionAlreadyStarted
    case noActiveTransaction
    case transactionDeadlock

    // MARK: - Migration
    case migrationFailed(version: String, error: any Error & Sendable)
    case migrationNotFound(version: String)
    case invalidMigrationFile(path: String, reason: String)
    case migrationVersionConflict(String)

    // MARK: - Configuration
    case configurationError(String)
    case missingEnvironmentVariable(String)
    case invalidCredentials

    // MARK: - Internal
    case internalError(String)
    case notImplemented(String)
}

extension SpectroError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let error):
            return "Database connection failed: \(error.localizedDescription)"
        case .connectionPoolExhausted:
            return "Database connection pool exhausted"
        case .invalidConnectionConfiguration(let message):
            return "Invalid connection configuration: \(message)"

        case .invalidQuery(let message):
            return "Invalid query: \(message)"
        case .invalidSql(let sql, let error):
            return "SQL execution failed for '\(sql)': \(error.localizedDescription)"
        case .invalidParameter(let name, let value, let reason):
            let base = "Invalid parameter '\(name)' with value '\(value ?? "nil")'"
            return reason.map { "\(base): \($0)" } ?? base
        case .queryExecutionFailed(let sql, let error):
            return "Query execution failed for '\(sql)': \(error.localizedDescription)"
        case .resultDecodingFailed(let column, let type):
            return "Failed to decode column '\(column)' as \(type)"

        case .notFound(let schema, let id):
            return "\(schema) with ID '\(id)' not found"
        case .staleRecord(let schema, let id):
            return "\(schema) with ID '\(id)' changed or was deleted since it was loaded"
        case .unexpectedResultCount(let expected, let actual):
            return "Expected \(expected) results but got \(actual)"
        case .invalidData(let field, let value, let reason):
            return "Invalid data for field '\(field)' with value '\(value ?? "nil")': \(reason)"
        case .validationError(let field, let errors):
            return "Validation failed for field '\(field)': \(errors.joined(separator: ", "))"
        case .changesetFailed(let errors, _):
            let messages = errors.errors.keys.sorted().flatMap { field in
                errors.errors[field, default: []].map { "\(field) \($0)" }
            }
            return "Changeset failed: \(messages.joined(separator: ", "))"
        case .constraintViolation(let message):
            return "Database constraint violation: \(message)"
        case .databaseError(let reason):
            return "Database error: \(reason)"

        case .invalidSchema(let reason):
            return "Invalid schema: \(reason)"
        case .invalidField(let schema, let field):
            return "Invalid field '\(field)' in schema '\(schema)'"
        case .relationshipError(let from, let to, let reason):
            return "Relationship error from '\(from)' to '\(to)': \(reason)"
        case .relationshipNotFound(let relationship, let schema):
            return "Relationship '\(relationship)' not found on schema '\(schema)'"
        case .missingRequiredField(let field):
            return "Required field '\(field)' missing"

        case .transactionFailed(let error):
            return "Transaction failed: \(error.localizedDescription)"
        case .transactionAndRollbackFailed(let original, let rollback):
            return "Transaction failed: \(original.localizedDescription). Rollback also failed: \(rollback.localizedDescription)"
        case .transactionAlreadyStarted:
            return "Transaction already started"
        case .noActiveTransaction:
            return "No active transaction"
        case .transactionDeadlock:
            return "Transaction deadlock detected"

        case .migrationFailed(let version, let error):
            return "Migration '\(version)' failed: \(error.localizedDescription)"
        case .migrationNotFound(let version):
            return "Migration '\(version)' not found"
        case .invalidMigrationFile(let path, let reason):
            return "Invalid migration file at '\(path)': \(reason)"
        case .migrationVersionConflict(let message):
            return "Migration version conflict: \(message)"

        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .missingEnvironmentVariable(let name):
            return "Missing required environment variable: \(name)"
        case .invalidCredentials:
            return "Invalid database credentials"

        case .internalError(let message):
            return "Internal error: \(message)"
        case .notImplemented(let feature):
            return "Feature not implemented: \(feature)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .connectionFailed:
            return "Check database server status and connection parameters"
        case .connectionPoolExhausted:
            return "Increase connection pool size or reduce concurrent operations"
        case .invalidConnectionConfiguration:
            return "Verify hostname, port, username, password, and database name"
        case .notFound:
            return "Verify the ID exists in the database"
        case .staleRecord:
            return "Reload the record and apply the change again"
        case .validationError, .changesetFailed:
            return "Check field requirements and constraints"
        case .transactionDeadlock:
            return "Retry the operation after a brief delay"
        case .missingEnvironmentVariable(let name):
            return "Set the \(name) environment variable"
        default:
            return nil
        }
    }
}

extension SpectroError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .invalidSql(let sql, let error):
            return "SpectroError.invalidSql(sql: \"\(sql)\", error: \(error))"
        case .queryExecutionFailed(let sql, let error):
            return "SpectroError.queryExecutionFailed(sql: \"\(sql)\", error: \(error))"
        default:
            // Interpolating self here re-enters debugDescription until the stack overflows.
            return "SpectroError: \(errorDescription ?? "Unknown error")"
        }
    }
}
