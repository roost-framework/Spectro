import Foundation

/// Encodable wrapper around a Changeset's validation errors for JSON API responses.
///
/// ```swift
/// let cs = Changeset.cast(nil, params: params, permitted: ["name", "email"])
///     .validateRequired(["name", "email"])
///
/// if !cs.isValid {
///     let body = try JSONEncoder().encode(cs.errorPayload)
///     // {"errors":{"name":["can't be blank"]}}
/// }
/// ```
public struct ChangesetErrors: Encodable, Sendable {
    public let errors: [String: [String]]

    public init(errors: [String: [String]]) {
        self.errors = errors
    }

    public init<T: Schema>(_ changeset: Changeset<T>) {
        self.errors = changeset.errors
    }
}

extension SpectroError {
    /// Structured field errors from a declared constraint, including those wrapped by a transaction.
    /// For local validation, read the original changeset's `errorPayload` instead.
    public var fieldErrors: ChangesetErrors? {
        switch self {
        case .changesetFailed(let errors, _):
            return errors
        case .transactionFailed(let underlying),
             .transactionAndRollbackFailed(let underlying, _):
            return (underlying as? SpectroError)?.fieldErrors
        default:
            return nil
        }
    }
}
