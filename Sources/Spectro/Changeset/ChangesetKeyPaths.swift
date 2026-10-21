import Foundation

// MARK: - Key Paths

/// Key path forms of the changeset API. A key path names a field as `@Schema` maps it, so a
/// renamed property fails to compile instead of being silently dropped, and typed values are
/// checked by the compiler.
///
/// ```swift
/// let changeset = Changeset.cast(nil, params: params, permitting: \.name, \.email)
///     .validateRequired(\.name, \.email)
///     .validateLength(\.name, min: 2)
///     .validateInclusion(\.role, in: [.member, .admin])
///     .putChange(\.isActive, true)
/// ```
extension Changeset {
    /// The property name a key path refers to.
    static func fieldName(_ keyPath: PartialKeyPath<T>) -> String {
        T._keyPathToColumn[keyPath] ?? "\(keyPath)".components(separatedBy: ".").last ?? "\(keyPath)"
    }

    /// `cast(_:params:permitted:)` with key paths.
    public static func cast(_ data: T?, params: [String: any Sendable], permitting fields: PartialKeyPath<T>...) -> Changeset<T> {
        cast(data, params: params, permitted: fields.map(fieldName))
    }

    /// The pending change of a field; `nil` without one, or for a change to `nil`.
    public func getChange<V>(_ field: KeyPath<T, V>) -> V? {
        typed(getChange(Self.fieldName(field)))
    }

    /// The pending change of a field, or its value in `data`; `nil` when neither is set.
    public func getField<V>(_ field: KeyPath<T, V>) -> V? {
        typed(getField(Self.fieldName(field)))
    }

    /// A value as the field's type, with a nil `Optional` as `nil` rather than `.some(nil)`.
    private func typed<V>(_ value: Any?) -> V? {
        guard let value, !isNilAny(value) else { return nil }
        return value as? V
    }

    /// Replace or add a change, with a value of the field's type.
    public func putChange<V: Sendable>(_ field: KeyPath<T, V>, _ value: V) -> Changeset<T> {
        putChange(Self.fieldName(field), value: value)
    }

    /// Remove the change of a field.
    public func deleteChange(_ field: PartialKeyPath<T>) -> Changeset<T> {
        deleteChange(Self.fieldName(field))
    }

    /// Add an error to a field.
    public func addError(_ field: PartialKeyPath<T>, message: String) -> Changeset<T> {
        addError(Self.fieldName(field), message: message)
    }

    /// The errors of a field.
    public func errors(on field: PartialKeyPath<T>) -> [String] {
        errors[Self.fieldName(field)] ?? []
    }

    /// `validateRequired(_:)` with key paths.
    public func validateRequired(_ fields: PartialKeyPath<T>...) -> Changeset<T> {
        validateRequired(fields.map(Self.fieldName))
    }

    /// `validateLength(_:min:max:is:)` with a key path.
    public func validateLength(_ field: KeyPath<T, String>, min: Int? = nil, max: Int? = nil, is exact: Int? = nil) -> Changeset<T> {
        validateLength(Self.fieldName(field), min: min, max: max, is: exact)
    }

    /// `validateLength(_:min:max:is:)` with a key path to an optional string.
    public func validateLength(_ field: KeyPath<T, String?>, min: Int? = nil, max: Int? = nil, is exact: Int? = nil) -> Changeset<T> {
        validateLength(Self.fieldName(field), min: min, max: max, is: exact)
    }

    /// `validateFormat(_:pattern:message:)` with a key path.
    public func validateFormat(_ field: KeyPath<T, String>, pattern: String, message: String? = nil) -> Changeset<T> {
        validateFormat(Self.fieldName(field), pattern: pattern, message: message)
    }

    /// `validateFormat(_:pattern:message:)` with a key path to an optional string.
    public func validateFormat(_ field: KeyPath<T, String?>, pattern: String, message: String? = nil) -> Changeset<T> {
        validateFormat(Self.fieldName(field), pattern: pattern, message: message)
    }

    /// The field's value is one of `allowed`, compared as values of the field's type.
    public func validateInclusion<V: Equatable & Sendable>(_ field: KeyPath<T, V>, in allowed: [V], message: String? = nil) -> Changeset<T> {
        validateCustom(field) { allowed.contains($0) ? nil : message ?? "is invalid" }
    }

    /// The field's value is none of `disallowed`, compared as values of the field's type.
    public func validateExclusion<V: Equatable & Sendable>(_ field: KeyPath<T, V>, in disallowed: [V], message: String? = nil) -> Changeset<T> {
        validateCustom(field) { disallowed.contains($0) ? message ?? "is reserved" : nil }
    }

    /// `validateNumber(_:greaterThan:greaterThanOrEqualTo:lessThan:lessThanOrEqualTo:equalTo:)` with a key path.
    public func validateNumber<V: Numeric>(
        _ field: KeyPath<T, V>,
        greaterThan: Double? = nil, greaterThanOrEqualTo: Double? = nil,
        lessThan: Double? = nil, lessThanOrEqualTo: Double? = nil, equalTo: Double? = nil
    ) -> Changeset<T> {
        validateNumber(Self.fieldName(field), greaterThan: greaterThan, greaterThanOrEqualTo: greaterThanOrEqualTo,
                       lessThan: lessThan, lessThanOrEqualTo: lessThanOrEqualTo, equalTo: equalTo)
    }

    /// Run `check` on the field's value, typed as the field, unless it is nil; it returns an
    /// error message, or `nil` when the value is valid.
    public func validateCustom<V>(_ field: KeyPath<T, V>, _ check: @Sendable (V) -> String?) -> Changeset<T> {
        let name = Self.fieldName(field)
        guard let value = getField(name), !isNilAny(value), let typed = value as? V, let message = check(typed) else { return self }
        return addError(name, message: message)
    }

    /// `uniqueConstraint(_:name:onTable:message:)` with a key path.
    public func uniqueConstraint(_ field: PartialKeyPath<T>, name: String, onTable: String? = nil, message: String = "has already been taken") -> Changeset<T> {
        uniqueConstraint(Self.fieldName(field), name: name, onTable: onTable, message: message)
    }

    /// `foreignKeyConstraint(_:name:onTable:message:)` with a key path.
    public func foreignKeyConstraint(_ field: PartialKeyPath<T>, name: String, onTable: String? = nil, message: String = "does not exist") -> Changeset<T> {
        foreignKeyConstraint(Self.fieldName(field), name: name, onTable: onTable, message: message)
    }

    /// `checkConstraint(_:name:onTable:message:)` with a key path.
    public func checkConstraint(_ field: PartialKeyPath<T>, name: String, onTable: String? = nil, message: String = "is invalid") -> Changeset<T> {
        checkConstraint(Self.fieldName(field), name: name, onTable: onTable, message: message)
    }

    /// `optimisticLock(_:)` with a key path to an integer version field.
    public func optimisticLock(_ field: KeyPath<T, Int>) -> Changeset<T> {
        optimisticLock(Self.fieldName(field))
    }
}
