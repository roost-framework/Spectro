import Foundation
import CoreFoundation

/// An Ecto-inspired changeset for tracking, casting, and validating changes to a `Schema`.
///
/// `Changeset` is a **value type** — every validation method returns a new changeset,
/// enabling an immutable pipeline style identical to `Query<T>`:
///
/// ```swift
/// let cs = Changeset.cast(nil, params: params, permitted: ["name", "email"])
///     .validateRequired(["name", "email"])
///     .validateLength("name", min: 2, max: 100)
///     .validateFormat("email", pattern: "^.+@.+\\..+$")
///
/// let user = try await repo.insert(cs)
/// ```
///
/// For updates, pass the existing record as `data`:
///
/// ```swift
/// let cs = Changeset.cast(existingUser, params: ["name": "Alice"], permitted: ["name"])
///     .validateRequired(["name"])
/// ```
public struct Changeset<T: Schema>: Sendable {

    /// A declared database constraint that may be presented as a field error.
    private struct ConstraintDeclaration: Sendable {
        let sqlState: String
        let field: String
        let name: String
        let table: String
        let message: String
    }

    // MARK: - Properties

    /// The original schema instance. `nil` for insert changesets.
    public let data: T?

    /// Pending changes that passed casting (field name → value).
    public private(set) var changes: [String: any Sendable]

    /// The params given to `cast`, from which `castEmbed` reads nested params.
    public private(set) var params: [String: any Sendable] = [:]

    /// Accumulated validation errors (field name → error messages).
    public internal(set) var errors: [String: [String]]

    private var constraintDeclarations: [ConstraintDeclaration] = []

    /// The version field of `optimisticLock(_:)`.
    private(set) var lockField: String?

    /// The functions of `prepareChanges(_:)`, in the order they were added.
    var preparations: [@Sendable (Changeset<T>, any Repo) async throws -> Changeset<T>] = []

    /// Writes of `castAssoc` and `putAssoc` by relationship, run once the record is saved,
    /// which load the relationship into it.
    var associationWrites: [(relationship: String, write: @Sendable (T, any Repo) async throws -> T)] = []

    /// The set of field names that were permitted during `cast`.
    public let permitted: Set<String>

    /// Whether the changeset has no validation errors.
    public var isValid: Bool { errors.isEmpty }

    /// The action this changeset represents — useful for conditional validation.
    public let action: Action?

    // MARK: - Action

    public enum Action: String, Sendable {
        case insert
        case update
    }

    // MARK: - Initialization

    /// Create a changeset directly. Prefer `Changeset.cast(...)` for most use cases.
    public init(
        data: T? = nil,
        changes: [String: any Sendable] = [:],
        errors: [String: [String]] = [:],
        permitted: Set<String> = [],
        action: Action? = nil
    ) {
        self.data = data
        self.changes = changes
        self.errors = errors
        self.permitted = permitted
        self.action = action
    }

    // MARK: - Cast

    /// Cast external parameters to schema types, filtering to permitted schema fields.
    ///
    /// This is the primary entry point for creating changesets. Unknown or
    /// non-permitted fields are silently dropped (not treated as errors),
    /// matching Ecto's strong-params approach.
    /// Scalar strings are converted to numbers, booleans, UUIDs, and ISO 8601 dates.
    /// Invalid values add an "is invalid" error and are excluded from changes.
    public static func cast(
        _ data: T?,
        params: [String: any Sendable],
        permitted: [String]
    ) -> Changeset<T> {
        let permittedSet = Set(permitted)
        let fields = Dictionary(uniqueKeysWithValues: SchemaRegistry.extractMetadata(from: T.self).fields.map { ($0.name, $0) })
        var changes: [String: any Sendable] = [:]
        var errors: [String: [String]] = [:]

        for (key, value) in params where permittedSet.contains(key) {
            guard let field = fields[key] else { continue }
            if let castValue = castValue(value, for: field) {
                changes[key] = castValue
            } else {
                errors[key] = ["is invalid"]
            }
        }

        let action: Action? = data == nil ? .insert : .update

        var changeset = Changeset(
            data: data,
            changes: changes,
            errors: errors,
            permitted: permittedSet,
            action: action
        )
        changeset.params = params
        return changeset
    }

    // MARK: - Field Access

    /// Get the pending change for a field, if any.
    public func getChange(_ field: String) -> (any Sendable)? {
        changes[field]
    }

    /// Get the effective value for a field: the pending change if present,
    /// otherwise the original value from `data` via Mirror reflection.
    ///
    /// Returns `Any?` rather than `(any Sendable)?` because Mirror erases
    /// types to `Any`, and Swift 6 disallows conditional casts to `Sendable`.
    public func getField(_ field: String) -> Any? {
        if let change = changes[field] {
            return change
        }
        guard let data = data else { return nil }
        return extractFieldValue(from: data, named: field)
    }

    /// Replace or add a change programmatically (outside of cast).
    public func putChange(_ field: String, value: any Sendable) -> Changeset<T> {
        var copy = self
        copy.changes[field] = value
        return copy
    }

    /// Remove a change for a field.
    public func deleteChange(_ field: String) -> Changeset<T> {
        var copy = self
        copy.changes.removeValue(forKey: field)
        return copy
    }

    // MARK: - Error Management

    /// Add a validation error for a field.
    public func addError(_ field: String, message: String) -> Changeset<T> {
        var copy = self
        copy.errors[field, default: []].append(message)
        return copy
    }

    // MARK: - Optimistic Locking

    /// Guard an update against concurrent ones, like Ecto's `optimistic_lock`. The update
    /// increments the integer `field` and matches the row only while it still holds the
    /// loaded value; otherwise it throws `SpectroError.staleRecord`.
    ///
    /// ```swift
    /// // @Column var lockVersion: Int = 1, with a "lock_version" integer column
    /// let updated = try await repo.update(
    ///     Changeset.cast(post, params: params, permitted: ["title"]).optimisticLock()
    /// )
    /// ```
    ///
    /// The update runs even without other changes, so it still increments the version.
    public func optimisticLock(_ field: String = "lockVersion") -> Changeset<T> {
        var copy = self
        copy.lockField = field
        return copy
    }

    // MARK: - Database Constraints

    /// Present a violation of the named unique constraint or index on `field` as a field error.
    /// PostgreSQL still checks uniqueness when the insert or update runs. The server must report
    /// the model's table by default; `onTable` names another exact physical origin, such as a
    /// partition leaf. A server error without a table name remains the original database error.
    public func uniqueConstraint(
        _ field: String,
        name: String,
        onTable: String? = nil,
        message: String = "has already been taken"
    ) -> Changeset<T> {
        declaringConstraint(sqlState: "23505", field: field, name: name, table: onTable ?? T.tableName, message: message)
    }

    /// Present a violation of the named foreign key constraint on `field` as a field error.
    /// The server must report the model's table by default. `onTable` names another exact
    /// physical origin; an error without a reported table remains the original database error.
    public func foreignKeyConstraint(
        _ field: String,
        name: String,
        onTable: String? = nil,
        message: String = "does not exist"
    ) -> Changeset<T> {
        declaringConstraint(sqlState: "23503", field: field, name: name, table: onTable ?? T.tableName, message: message)
    }

    /// Present a violation of the named check constraint on `field` as a field error.
    /// The server must report the model's table by default. `onTable` names another exact
    /// physical origin, such as a partition leaf; a missing origin leaves the error unchanged.
    public func checkConstraint(
        _ field: String,
        name: String,
        onTable: String? = nil,
        message: String = "is invalid"
    ) -> Changeset<T> {
        declaringConstraint(sqlState: "23514", field: field, name: name, table: onTable ?? T.tableName, message: message)
    }

    private func declaringConstraint(
        sqlState: String, field: String, name: String, table: String, message: String
    ) -> Changeset<T> {
        var copy = self
        copy.constraintDeclarations.append(.init(sqlState: sqlState, field: field, name: name, table: table, message: message))
        return copy
    }

    /// Reject a declaration whose target is not a schema property before issuing SQL.
    func validateConstraintDeclarations() throws {
        let fields = Set(SchemaRegistry.extractMetadata(from: T.self).fields.map(\.name))
        for declaration in constraintDeclarations where !fields.contains(declaration.field) {
            throw SpectroError.invalidField(schema: String(describing: T.self), field: declaration.field)
        }
    }

    /// Map only a declared PostgreSQL constraint failure from the declared physical table to structured field errors.
    /// An unmatched error remains the original database error.
    func constraintFailure(for error: SpectroError) -> SpectroError? {
        guard let server = error.serverError,
              let name = server.constraintName,
              let table = server.tableName else { return nil }
        let matching = constraintDeclarations.filter {
            $0.sqlState == server.sqlState && $0.name == name && $0.table == table
        }
        guard !matching.isEmpty else { return nil }
        var fieldErrors = errors
        for declaration in matching {
            if !fieldErrors[declaration.field, default: []].contains(declaration.message) {
                fieldErrors[declaration.field, default: []].append(declaration.message)
            }
        }
        return .changesetFailed(errors: ChangesetErrors(errors: fieldErrors), underlying: error)
    }

    // MARK: - Validation

    /// Validate that the given fields have non-nil, non-empty values (either in changes or data).
    ///
    /// Like Ecto's `validate_required`, this rejects both nil values and empty/whitespace-only strings.
    public func validateRequired(_ fields: [String]) -> Changeset<T> {
        var copy = self
        for field in fields {
            let value = copy.getField(field)
            if value == nil || isNilAny(value!) {
                copy.errors[field, default: []].append("can't be blank")
            } else if let str = value as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.errors[field, default: []].append("can't be blank")
            }
        }
        return copy
    }

    /// Validate string length constraints on a field.
    public func validateLength(
        _ field: String,
        min: Int? = nil,
        max: Int? = nil,
        is exact: Int? = nil
    ) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        guard let str = value as? String else { return self }

        var copy = self
        if let min = min, str.count < min {
            copy.errors[field, default: []].append(
                "should be at least \(min) character(s)"
            )
        }
        if let max = max, str.count > max {
            copy.errors[field, default: []].append(
                "should be at most \(max) character(s)"
            )
        }
        if let exact = exact, str.count != exact {
            copy.errors[field, default: []].append(
                "should be \(exact) character(s)"
            )
        }
        return copy
    }

    /// Validate that a string field matches a regex pattern.
    public func validateFormat(_ field: String, pattern: String, message: String? = nil) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        guard let str = value as? String else { return self }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(str.startIndex..., in: str)
        if regex.firstMatch(in: str, range: range) == nil {
            var copy = self
            copy.errors[field, default: []].append(message ?? "has invalid format")
            return copy
        }
        return self
    }

    /// Validate that a field's value is one of the allowed values.
    public func validateInclusion(_ field: String, in allowed: [any Sendable], message: String? = nil) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        let valueStr = String(describing: value)
        let allowedStrs = allowed.map { String(describing: $0) }
        if !allowedStrs.contains(valueStr) {
            var copy = self
            copy.errors[field, default: []].append(message ?? "is invalid")
            return copy
        }
        return self
    }

    /// Validate that a field's value is NOT one of the disallowed values.
    public func validateExclusion(_ field: String, in disallowed: [any Sendable], message: String? = nil) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        let valueStr = String(describing: value)
        let disallowedStrs = disallowed.map { String(describing: $0) }
        if disallowedStrs.contains(valueStr) {
            var copy = self
            copy.errors[field, default: []].append(message ?? "is reserved")
            return copy
        }
        return self
    }

    /// Validate a numeric field against comparison constraints.
    public func validateNumber(
        _ field: String,
        greaterThan: Double? = nil,
        greaterThanOrEqualTo: Double? = nil,
        lessThan: Double? = nil,
        lessThanOrEqualTo: Double? = nil,
        equalTo: Double? = nil
    ) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        guard let num = toDouble(value) else { return self }

        var copy = self
        if let gt = greaterThan, !(num > gt) {
            copy.errors[field, default: []].append("must be greater than \(gt)")
        }
        if let gte = greaterThanOrEqualTo, !(num >= gte) {
            copy.errors[field, default: []].append("must be greater than or equal to \(gte)")
        }
        if let lt = lessThan, !(num < lt) {
            copy.errors[field, default: []].append("must be less than \(lt)")
        }
        if let lte = lessThanOrEqualTo, !(num <= lte) {
            copy.errors[field, default: []].append("must be less than or equal to \(lte)")
        }
        if let eq = equalTo, num != eq {
            copy.errors[field, default: []].append("must be equal to \(eq)")
        }
        return copy
    }

    /// Run a custom validation closure on a field.
    ///
    /// Return `nil` from the closure if valid, or an error message string if invalid.
    public func validateCustom(_ field: String, _ check: @Sendable (Any) -> String?) -> Changeset<T> {
        guard let value = getField(field) else { return self }
        if let message = check(value) {
            var copy = self
            copy.errors[field, default: []].append(message)
            return copy
        }
        return self
    }

    // MARK: - Serialization

    /// Encodable snapshot of validation errors for JSON API responses.
    public var errorPayload: ChangesetErrors { ChangesetErrors(self) }

    // MARK: - Async Validation

    /// Validate that no existing record in the database has the same value for `field`.
    ///
    /// For update changesets (`data != nil`), the current record is excluded from the
    /// check so a record can be saved with its own existing value.
    ///
    /// ```swift
    /// let cs = try await Changeset.cast(nil, params: params, permitted: ["email"])
    ///     .validateRequired(["email"])
    ///     .validateUniqueness("email", repo: repo)
    /// ```
    public func validateUniqueness(
        _ field: String,
        repo: some Repo,
        message: String? = nil
    ) async throws -> Changeset<T> {
        guard let value = getField(field) else { return self }

        let col = field.snakeCase().quoted
        let pgData = try SchemaMapper.convertToPostgresData(value)

        var query = repo.query(T.self)
            .where { _ in QueryCondition(sql: "\(col) = ?", parameters: [pgData]) }

        if let existing = data {
            let metadata = await SchemaRegistry.shared.register(T.self)
            if let pkField = metadata.primaryKeyField,
               let id = extractPrimaryKey(from: existing, fieldName: pkField) {
                let pkCol = pkField.snakeCase().quoted
                query = query.where { _ in QueryCondition(sql: "\(pkCol) != ?", parameters: [id.toPostgresData()]) }
            }
        }

        let count = try await query.count()
        if count > 0 {
            return addError(field, message: message ?? "has already been taken")
        }
        return self
    }

    // MARK: - Apply

    /// Return the changes dict, suitable for passing to `Repo.update`.
    ///
    /// Throws `SpectroError.validationError` if the changeset is invalid.
    public func applyChanges() throws -> [String: any Sendable] {
        guard isValid else {
            let allErrors = errors.flatMap { field, msgs in
                msgs.map { "\(field) \($0)" }
            }
            throw SpectroError.validationError(
                field: errors.keys.first ?? "unknown",
                errors: allErrors
            )
        }
        return changes
    }

    /// The record with the changes applied, such as a form's validated values, like Ecto's
    /// `apply_action`. For insert changesets (data == nil), the changes apply to a fresh `T()`.
    /// Relationships are not kept.
    ///
    /// Throws `SpectroError.validationError` if the changeset is invalid.
    public func applyToInstance() throws -> T {
        guard isValid else {
            let allErrors = errors.flatMap { field, msgs in
                msgs.map { "\(field) \($0)" }
            }
            throw SpectroError.validationError(
                field: errors.keys.first ?? "unknown",
                errors: allErrors
            )
        }
        return try applied()
    }

    /// The record with the changes applied, valid or not.
    func applied() throws -> T {
        let base = data ?? T()
        var values: [String: Any] = [:]
        for field in SchemaRegistry.extractMetadata(from: T.self).fields {
            values[field.name] = changes[field.name] ?? extractFieldValue(from: base, named: field.name)
        }
        return try T.buildInstance(from: values)
    }

    // MARK: - Private Helpers

    private static func castValue(_ value: any Sendable, for field: FieldInfo) -> (any Sendable)? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional && mirror.children.isEmpty {
            return field.isNullable ? value : nil
        }

        // Foundation bridges JSON booleans to NSNumber, and conditional casts
        // otherwise accept true as 1 and numeric 0/1 as Bool.
        if let number = value as? NSNumber {
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            if isBoolean != (field.fieldType == .bool) { return nil }
        }

        return field.valueType.cast(value)
    }

    /// Extract a field value from a schema instance by property name using Mirror.
    func extractFieldValue(from instance: T, named field: String) -> Any? {
        let mirror = Mirror(reflecting: instance)
        for child in mirror.children {
            guard let label = child.label else { continue }
            let fieldName = label.hasPrefix("_") ? String(label.dropFirst()) : label
            guard fieldName == field else { continue }

            // Unwrap property wrapper to get wrappedValue
            let wrapperMirror = Mirror(reflecting: child.value)
            for wrapperChild in wrapperMirror.children {
                if wrapperChild.label == "wrappedValue" {
                    return wrapperChild.value
                }
            }
            // Not a property wrapper — return raw value
            return child.value
        }
        return nil
    }

    /// Check if a value is nil (handles Optional<T> erased to Any).
    func isNilAny(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// Convert a value to Double for numeric validation.
    private func toDouble(_ value: Any) -> Double? {
        switch value {
        case let v as Decimal: return NSDecimalNumber(decimal: v).doubleValue
        case let v as Int:    return Double(v)
        case let v as Double: return v
        case let v as Float:  return Double(v)
        default: return nil
        }
    }
}
