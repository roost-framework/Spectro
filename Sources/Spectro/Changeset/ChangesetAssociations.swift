import Foundation

/// What `castAssoc` does with a loaded related record that the params leave out,
/// like Ecto's `on_replace`.
public enum OnReplace: Sendable {
    /// Add an error to the relationship, so the changeset is invalid.
    case markAsInvalid
    /// Delete the record.
    case delete
}

// MARK: - Associations

extension Changeset {
    /// Cast nested params into the records of a has-many relationship, like Ecto's `cast_assoc`.
    ///
    /// ```swift
    /// let changeset = Changeset<User>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
    ///     .castAssoc(\.$posts, params: [["title": "Hello"], ["title": "World"]]) { post, params in
    ///         Changeset.cast(post, params: params, permitted: ["title"]).validateRequired(["title"])
    ///     }
    /// let user = try await repo.insert(changeset)   // user.posts holds both posts
    /// ```
    ///
    /// `changeset` makes each record's changeset: of the loaded record whose primary key the
    /// params carry, or of a new record. Inserting or updating this changeset writes them, with
    /// the foreign key set, in one transaction, and returns the record with the relationship
    /// loaded. Their errors join this changeset's as `"posts[1].title"`.
    ///
    /// To update a record's relationship, preload it first. `onReplace` decides what happens to
    /// loaded records the params leave out.
    public func castAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        params: [[String: any Sendable]],
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid,
        with changeset: (Related?, [String: any Sendable]) -> Changeset<Related>
    ) -> Changeset<T> {
        let name = T._keyPathToColumn[keyPath] ?? "\(keyPath)"
        var loaded: [Related] = []
        if let data {
            let relation = data[keyPath: keyPath]
            guard relation.isLoaded else { return addError(name, message: "must be preloaded before casting") }
            loaded = relation.value ?? []
        }
        let relatedKey = SchemaRegistry.extractMetadata(from: Related.self).primaryKeyField
        func key(of record: Related) -> AnyHashable? {
            relatedKey.flatMap { PreloadQuery<Related>.extractPrimaryKeyPair(from: record, fieldName: $0)?.key }
        }
        var byKey: [AnyHashable: Related] = [:]
        for record in loaded { if let key = key(of: record) { byKey[key] = record } }

        var children: [(changeset: Changeset<Related>, existing: Related?)] = []
        for params in params {
            let existing = paramsKey(params, field: relatedKey, type: Related.self).flatMap { byKey.removeValue(forKey: $0) }
            children.append((changeset(existing, params), existing))
        }
        let removed = loaded.filter { record in key(of: record).map { byKey[$0] != nil } ?? false }

        var copy = self
        for (index, child) in children.enumerated() {
            for (field, messages) in child.changeset.errors {
                copy.errors["\(name)[\(index)].\(field)", default: []].append(contentsOf: messages)
            }
        }
        if !removed.isEmpty && onReplace == .markAsInvalid {
            copy.errors[name, default: []].append("is invalid")
        }

        let box = AssociationKeyPath(value: keyPath)
        let foreignKey = Self.foreignKeyProperty(foreignKey, of: Related.self)
        let writes = children
        copy.associationWrites.append { parent, repo in
            let parentKey = try Self.primaryKey(of: parent)
            var records: [Related] = []
            for child in writes {
                if child.existing != nil {
                    records.append(try await repo.update(child.changeset))
                } else {
                    records.append(try await repo.insert(child.changeset.putChange(foreignKey, value: parentKey)))
                }
            }
            for record in removed {
                try await repo.delete(Related.self, id: try Changeset<Related>.primaryKey(of: record))
            }
            var result = parent
            result[keyPath: box.value] = SpectroLazyRelation(loaded: records, relationshipInfo: parent[keyPath: box.value].relationshipInfo)
            return result
        }
        return copy
    }

    /// Cast nested params into the record of a has-one relationship, like Ecto's `cast_assoc`.
    ///
    /// Params update the loaded record, or insert one when there is none. `nil` params leave
    /// out the loaded record, which `onReplace` then marks invalid or deletes. For an update,
    /// preload the relationship first. Errors join this changeset's as `"profile.bio"`.
    public func castAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        params: [String: any Sendable]?,
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid,
        with changeset: (Related?, [String: any Sendable]) -> Changeset<Related>
    ) -> Changeset<T> {
        let name = T._keyPathToColumn[keyPath] ?? "\(keyPath)"
        guard T()[keyPath: keyPath].relationshipInfo.kind == .hasOne else {
            return addError(name, message: "is not a has-one relationship")
        }
        var existing: Related?
        if let data {
            let relation = data[keyPath: keyPath]
            guard relation.isLoaded else { return addError(name, message: "must be preloaded before casting") }
            existing = relation.value ?? nil
        }
        let child = params.map { changeset(existing, $0) }
        let current = existing

        var copy = self
        for (field, messages) in child?.errors ?? [:] {
            copy.errors["\(name).\(field)", default: []].append(contentsOf: messages)
        }
        let removed = child == nil ? current : nil
        if removed != nil && onReplace == .markAsInvalid {
            copy.errors[name, default: []].append("is invalid")
        }

        let box = AssociationKeyPath(value: keyPath)
        let foreignKey = Self.foreignKeyProperty(foreignKey, of: Related.self)
        copy.associationWrites.append { parent, repo in
            var record: Related?
            if let child {
                record = current != nil
                    ? try await repo.update(child)
                    : try await repo.insert(child.putChange(foreignKey, value: try Self.primaryKey(of: parent)))
            }
            if let removed {
                try await repo.delete(Related.self, id: try Changeset<Related>.primaryKey(of: removed))
            }
            var result = parent
            result[keyPath: box.value] = SpectroLazyRelation(loaded: record, relationshipInfo: parent[keyPath: box.value].relationshipInfo)
            return result
        }
        return copy
    }

    // MARK: - Preparing Changes

    /// Run `prepare` just before the insert or update, in its transaction, like Ecto's
    /// `prepare_changes`. It may read and write with the transaction's repository, and returns
    /// the changeset to write, such as one with a counter changed. An invalid changeset skips it.
    public func prepareChanges(_ prepare: @escaping @Sendable (Changeset<T>, any Repo) async throws -> Changeset<T>) -> Changeset<T> {
        var copy = self
        copy.preparations.append(prepare)
        return copy
    }

    // MARK: - Writing

    /// Whether writing the changeset takes more than one statement, and so a transaction.
    var needsTransaction: Bool { !preparations.isEmpty || !associationWrites.isEmpty }

    /// The changeset after its preparations, run with `repo` in order.
    func prepared(using repo: any Repo) async throws -> Changeset<T> {
        guard isValid else { return self }
        var changeset = self
        for prepare in preparations { changeset = try await prepare(changeset, repo) }
        return changeset
    }

    /// Write the cast associations of `record`, just saved, and return it with them loaded.
    func writeAssociations(of record: T, using repo: any Repo) async throws -> T {
        var record = record
        for write in associationWrites { record = try await write(record, repo) }
        return record
    }

    // MARK: - Helpers

    private func paramsKey<S: Schema>(_ params: [String: any Sendable], field: String?, type: S.Type) -> AnyHashable? {
        guard let field, let value = params[field] else { return nil }
        let info = SchemaRegistry.extractMetadata(from: S.self).fields.first { $0.name == field }
        return (info?.valueType.cast(value) as? any Hashable).map { AnyHashable($0) }
    }

    /// A foreign key given as a property or a column name, as the related property name.
    private static func foreignKeyProperty<S: Schema>(_ foreignKey: String?, of type: S.Type) -> String {
        let name = foreignKey ?? PreloadQuery<T>.conventionalForeignKey(for: T.self)
        let fields = SchemaRegistry.extractMetadata(from: S.self).fields
        return (fields.first { $0.name == name } ?? fields.first { $0.databaseName == name })?.name ?? name
    }

    static func primaryKey(of record: T) throws -> any PrimaryKeyType {
        guard let field = SchemaRegistry.extractMetadata(from: T.self).primaryKeyField,
              let key = extractPrimaryKey(from: record, fieldName: field) else {
            throw SpectroError.invalidSchema(reason: "Could not extract primary key value from \(T.self)")
        }
        return key
    }
}

/// A key path closures can capture; see `PreloadQuery`'s `KPBox`.
private struct AssociationKeyPath<Root, Value>: @unchecked Sendable {
    let value: WritableKeyPath<Root, Value>
}
