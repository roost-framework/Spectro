import Foundation
@preconcurrency import PostgresNIO

/// What `castAssoc` and `putAssoc` do with a loaded related record left out, like Ecto's
/// `on_replace`.
public enum OnReplace: Sendable {
    /// Add an error to the relationship, so the changeset is invalid.
    case markAsInvalid
    /// Delete the record. For a many-to-many relationship, delete only its join row, as Ecto does.
    case delete
}

// MARK: - Associations

extension Changeset {
    /// Cast nested params into the records of a has-many or many-to-many relationship, like
    /// Ecto's `cast_assoc`.
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
    /// the foreign key set or, for many-to-many, the join rows inserted, in one transaction, and
    /// returns the record with the relationship loaded. Their errors join this changeset's as
    /// `"posts[1].title"`.
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
        let relatedKey = SchemaRegistry.extractMetadata(from: Related.self).primaryKeyField
        return associateMany(keyPath, foreignKey: foreignKey, onReplace: onReplace) { loaded in
            var unmatched = loaded
            return params.map { params in
                changeset(paramsKey(params, field: relatedKey, type: Related.self).flatMap { unmatched.removeValue(forKey: $0) }, params)
            }
        }
    }

    /// Make `records`, already stored, the records of a has-many or many-to-many relationship,
    /// like Ecto's `put_assoc`.
    ///
    /// ```swift
    /// let tags = try await repo.query(Tag.self).where { $0.name.in(["swift", "sql"]) }.all()
    /// let post = try await repo.update(Changeset.cast(post, params: [:], permitted: []).putAssoc(\.$tags, tags))
    /// ```
    ///
    /// Writing the changeset inserts the join rows of a many-to-many relationship that are
    /// missing, or sets the foreign key of has-many records that belong elsewhere. `onReplace`
    /// decides what happens to loaded records that `records` leave out. To insert or change
    /// related records too, pass their changesets instead.
    public func putAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        _ records: [Related],
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid
    ) -> Changeset<T> {
        putAssoc(keyPath, records.map { Changeset<Related>(data: $0, action: .update) }, foreignKey: foreignKey, onReplace: onReplace)
    }

    /// `putAssoc(_:_:foreignKey:onReplace:)` with changesets: one without data inserts a record,
    /// one with data updates it. Their errors join this changeset's as `"tags[1].name"`.
    @_disfavoredOverload
    public func putAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        _ changesets: [Changeset<Related>],
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid
    ) -> Changeset<T> {
        associateMany(keyPath, foreignKey: foreignKey, onReplace: onReplace) { _ in changesets }
    }

    /// Cast nested params into the record of a has-one relationship, like Ecto's `cast_assoc`.
    ///
    /// Params update the loaded record, or insert one when there is none or when they carry
    /// another primary key. `nil` params, or another key, leave out the loaded record, which
    /// `onReplace` then marks invalid or deletes. For an update, preload the relationship first.
    /// Errors join this changeset's as `"profile.bio"`.
    public func castAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        params: [String: any Sendable]?,
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid,
        with changeset: (Related?, [String: any Sendable]) -> Changeset<Related>
    ) -> Changeset<T> {
        let relatedKey = SchemaRegistry.extractMetadata(from: Related.self).primaryKeyField
        return associateOne(keyPath, foreignKey: foreignKey, onReplace: onReplace) { loaded in
            guard let params else { return nil }
            // Params carrying another record's key replace the loaded record, as in Ecto.
            let givenKey = paramsKey(params, field: relatedKey, type: Related.self)
            let matches = givenKey == nil || givenKey == loaded.flatMap(recordKey)?.key
            return changeset(matches ? loaded : nil, params)
        }
    }

    /// Make `record`, already stored, the record of a has-one relationship, like Ecto's
    /// `put_assoc`. Writing the changeset sets its foreign key; `nil` leaves out the loaded
    /// record, which `onReplace` then marks invalid or deletes, as does another record.
    public func putAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        _ record: Related?,
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid
    ) -> Changeset<T> {
        putAssoc(keyPath, record.map { Changeset<Related>(data: $0, action: .update) }, foreignKey: foreignKey, onReplace: onReplace)
    }

    /// `putAssoc(_:_:foreignKey:onReplace:)` with a changeset: one without data inserts the
    /// record, one with data updates it. Its errors join this changeset's as `"profile.bio"`.
    @_disfavoredOverload
    public func putAssoc<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        _ changeset: Changeset<Related>?,
        foreignKey: String? = nil,
        onReplace: OnReplace = .markAsInvalid
    ) -> Changeset<T> {
        associateOne(keyPath, foreignKey: foreignKey, onReplace: onReplace) { _ in changeset }
    }

    /// Change a has-many or many-to-many relationship to the records of `children`, made from
    /// the loaded records by primary key. A child with data keeps the loaded record of its key.
    private func associateMany<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String?,
        onReplace: OnReplace,
        children makeChildren: ([AnyHashable: Related]) -> [Changeset<Related>]
    ) -> Changeset<T> {
        let name = T._keyPathToColumn[keyPath] ?? "\(keyPath)"
        let info = T()[keyPath: keyPath].relationshipInfo
        guard info.kind == .hasMany || info.kind == .manyToMany else {
            return addError(name, message: "is not a has-many or many-to-many relationship")
        }
        let junction = info.kind == .manyToMany ? PreloadQuery<T>.junction(info, to: Related.self) : nil
        guard junction?.table.isEmpty != true else { return addError(name, message: "has no junction table") }
        var loaded: [Related] = []
        if let data {
            let relation = data[keyPath: keyPath]
            guard relation.isLoaded else { return addError(name, message: "must be preloaded before casting") }
            loaded = relation.value ?? []
        }
        var byKey: [AnyHashable: Related] = [:]
        for record in loaded { if let key = recordKey(record)?.key { byKey[key] = record } }
        let children = makeChildren(byKey)
        let kept = Set(children.compactMap { $0.data.flatMap(recordKey)?.key })
        let removed = loaded.filter { record in recordKey(record).map { !kept.contains($0.key) } ?? false }

        var copy = self
        copy.replaceAssociation(name)
        for (index, child) in children.enumerated() {
            for (field, messages) in child.errors {
                copy.errors["\(name)[\(index)].\(field)", default: []].append(contentsOf: messages)
            }
        }
        if !removed.isEmpty && onReplace == .markAsInvalid {
            copy.errors[name, default: []].append("is invalid")
        }

        let box = AssociationKeyPath(value: keyPath)
        let foreignKey = Self.foreignKeyProperty(foreignKey, of: Related.self)
        let isLoaded = children.map { child in child.data.flatMap(recordKey).map { byKey[$0.key] != nil } ?? false }
        copy.associationWrites.append((name, { parent, repo in
            let parentKey = try Self.primaryKey(of: parent)
            // Deleting first frees unique values for the records written after.
            for record in removed {
                if let junction {
                    try await junction.unlink(parentKey, try Changeset<Related>.primaryKey(of: record), using: repo)
                } else {
                    try await repo.delete(Related.self, id: try Changeset<Related>.primaryKey(of: record))
                }
            }
            var records: [Related] = []
            for (child, isLoaded) in zip(children, isLoaded) {
                let child = junction == nil && !isLoaded ? child.putChange(foreignKey, value: parentKey) : child
                let record = child.data == nil ? try await repo.insert(child) : try await repo.update(child)
                if let junction, !isLoaded {
                    try await junction.link(parentKey, try Changeset<Related>.primaryKey(of: record), using: repo)
                }
                records.append(record)
            }
            var result = parent
            result[keyPath: box.value] = SpectroLazyRelation(loaded: records, relationshipInfo: parent[keyPath: box.value].relationshipInfo)
            return result
        }))
        return copy
    }

    /// Change a has-one relationship to the record of `child`, made from the loaded record.
    /// A child with the loaded record's key keeps it.
    private func associateOne<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String?,
        onReplace: OnReplace,
        child makeChild: (Related?) -> Changeset<Related>?
    ) -> Changeset<T> {
        let name = T._keyPathToColumn[keyPath] ?? "\(keyPath)"
        guard T()[keyPath: keyPath].relationshipInfo.kind == .hasOne else {
            return addError(name, message: "is not a has-one relationship")
        }
        var loaded: Related?
        if let data {
            let relation = data[keyPath: keyPath]
            guard relation.isLoaded else { return addError(name, message: "must be preloaded before casting") }
            loaded = relation.value ?? nil
        }
        let child = makeChild(loaded)
        let loadedKey = loaded.flatMap(recordKey)?.key
        let isLoaded = loadedKey != nil && child?.data.flatMap(recordKey)?.key == loadedKey
        let removed = loadedKey != nil && !isLoaded ? loaded : nil

        var copy = self
        copy.replaceAssociation(name)
        for (field, messages) in child?.errors ?? [:] {
            copy.errors["\(name).\(field)", default: []].append(contentsOf: messages)
        }
        if removed != nil && onReplace == .markAsInvalid {
            copy.errors[name, default: []].append("is invalid")
        }

        let box = AssociationKeyPath(value: keyPath)
        let foreignKey = Self.foreignKeyProperty(foreignKey, of: Related.self)
        copy.associationWrites.append((name, { parent, repo in
            if let removed {
                try await repo.delete(Related.self, id: try Changeset<Related>.primaryKey(of: removed))
            }
            var record: Related?
            if var child {
                if !isLoaded { child = child.putChange(foreignKey, value: try Self.primaryKey(of: parent)) }
                record = child.data == nil ? try await repo.insert(child) : try await repo.update(child)
            }
            var result = parent
            result[keyPath: box.value] = SpectroLazyRelation(loaded: record, relationshipInfo: parent[keyPath: box.value].relationshipInfo)
            return result
        }))
        return copy
    }

    /// Drop an earlier cast or put of the relationship `name`, with its errors: a later one
    /// replaces it, as in Ecto.
    private mutating func replaceAssociation(_ name: String) {
        associationWrites.removeAll { $0.relationship == name }
        errors = errors.filter { key, _ in key != name && !key.hasPrefix("\(name)[") && !key.hasPrefix("\(name).") }
    }

    // MARK: - Embeds

    /// Cast the field's nested params, from the params given to `cast`, into an embedded schema,
    /// like Ecto's `cast_embed`.
    ///
    /// ```swift
    /// let changeset = Changeset<User>.cast(user, params: params, permitted: ["name"])
    ///     .castEmbed(\.address) { address, params in
    ///         Changeset.cast(address, params: params, permitted: ["street", "city"]).validateRequired(["city"])
    ///     }
    /// ```
    ///
    /// Without params for the field, its value stays as it is; `nil` or `NSNull` removes it.
    /// Params update the record's value, unless they carry another primary key, which makes a new
    /// value. The value becomes a change of the field, written with the record, and its errors
    /// join this changeset's as `"address.city"`. Params that are not a dictionary are invalid.
    /// `cast` itself accepts only values of the embedded type for the field.
    public func castEmbed<Embedded: Schema & DatabaseValue>(
        _ keyPath: KeyPath<T, Embedded?>,
        with changeset: (Embedded?, [String: any Sendable]) -> Changeset<Embedded>
    ) -> Changeset<T> {
        let name = Self.fieldName(keyPath)
        guard let value = params[name] else { return self }
        if isNilAny(value) || value is NSNull { return putEmbed(keyPath, nil as Embedded?) }
        guard let params = value as? [String: any Sendable] else { return invalidEmbed(name) }
        return putEmbed(keyPath, embedChangeset(data?[keyPath: keyPath] ?? nil, params, changeset))
    }

    /// `castEmbed(_:with:)` for a field that always holds a value.
    public func castEmbed<Embedded: Schema & DatabaseValue>(
        _ keyPath: KeyPath<T, Embedded>,
        with changeset: (Embedded?, [String: any Sendable]) -> Changeset<Embedded>
    ) -> Changeset<T> {
        let name = Self.fieldName(keyPath)
        guard let value = params[name] else { return self }
        guard let params = value as? [String: any Sendable] else { return invalidEmbed(name) }
        return putEmbed(keyPath, embedChangeset(data?[keyPath: keyPath], params, changeset))
    }

    /// Cast the field's list of nested params into a list of embedded schemas, like Ecto's
    /// `cast_embed` for `embeds_many`. Params carrying the primary key of one of the record's
    /// values update it, others make new values, and the values they leave out are removed.
    /// Errors join this changeset's as `"phones[1].number"`.
    public func castEmbed<Embedded: Schema & DatabaseValue>(
        _ keyPath: KeyPath<T, [Embedded]>,
        with changeset: (Embedded?, [String: any Sendable]) -> Changeset<Embedded>
    ) -> Changeset<T> {
        let name = Self.fieldName(keyPath)
        guard let value = params[name] else { return self }
        guard let list = value as? [[String: any Sendable]] else { return invalidEmbed(name) }
        let key = SchemaRegistry.extractMetadata(from: Embedded.self).primaryKeyField
        var unmatched: [AnyHashable: Embedded] = [:]
        for value in data?[keyPath: keyPath] ?? [] {
            if let valueKey = recordKey(value)?.key { unmatched[valueKey] = value }
        }
        return putEmbed(keyPath, list.map { params in
            changeset(paramsKey(params, field: key, type: Embedded.self).flatMap { unmatched.removeValue(forKey: $0) }, params)
        })
    }

    /// Set an embedded schema, like Ecto's `put_embed`; `nil` removes it.
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, Embedded?>, _ value: Embedded?) -> Changeset<T> {
        putEmbed(keyPath, value.map { Changeset<Embedded>(data: $0, action: .update) })
    }

    /// `putEmbed(_:_:)` with a changeset, whose errors join this changeset's as `"address.city"`.
    @_disfavoredOverload
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, Embedded?>, _ changeset: Changeset<Embedded>?) -> Changeset<T> {
        embed(Self.fieldName(keyPath), changeset.map { [$0] } ?? []) { $0.first }
    }

    /// `putEmbed(_:_:)` for a field that always holds a value.
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, Embedded>, _ value: Embedded) -> Changeset<T> {
        putEmbed(keyPath, Changeset<Embedded>(data: value, action: .update))
    }

    /// `putEmbed(_:_:)` with a changeset, for a field that always holds a value.
    @_disfavoredOverload
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, Embedded>, _ changeset: Changeset<Embedded>) -> Changeset<T> {
        embed(Self.fieldName(keyPath), [changeset]) { $0[0] }
    }

    /// Set a list of embedded schemas, like Ecto's `put_embed` for `embeds_many`.
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, [Embedded]>, _ values: [Embedded]) -> Changeset<T> {
        putEmbed(keyPath, values.map { Changeset<Embedded>(data: $0, action: .update) })
    }

    /// `putEmbed(_:_:)` with changesets, whose errors join this changeset's as `"phones[1].number"`.
    @_disfavoredOverload
    public func putEmbed<Embedded: Schema & DatabaseValue>(_ keyPath: KeyPath<T, [Embedded]>, _ changesets: [Changeset<Embedded>]) -> Changeset<T> {
        embed(Self.fieldName(keyPath), changesets, many: true) { $0 }
    }

    /// The changeset of an embedded value for `params`: of `current`, unless they carry another key.
    private func embedChangeset<Embedded: Schema>(
        _ current: Embedded?, _ params: [String: any Sendable],
        _ changeset: (Embedded?, [String: any Sendable]) -> Changeset<Embedded>
    ) -> Changeset<Embedded> {
        let key = paramsKey(params, field: SchemaRegistry.extractMetadata(from: Embedded.self).primaryKeyField, type: Embedded.self)
        return changeset(key == nil || key == current.flatMap(recordKey)?.key ? current : nil, params)
    }

    /// Make the values of `changesets`, put together by `value`, the change of the field `name`,
    /// replacing an earlier cast or put of it. Errors join as `"name.field"`, or as
    /// `"name[1].field"` for `many`.
    private func embed<Embedded: Schema, Value: Sendable>(
        _ name: String, _ changesets: [Changeset<Embedded>], many: Bool = false, as value: ([Embedded]) -> Value
    ) -> Changeset<T> {
        var copy = self
        copy.replaceAssociation(name)
        for (index, child) in changesets.enumerated() {
            for (field, messages) in child.errors {
                copy.errors["\(many ? "\(name)[\(index)]" : name).\(field)", default: []].append(contentsOf: messages)
            }
        }
        let values = changesets.compactMap { try? $0.applied() }
        guard values.count == changesets.count else { return copy.deleteChange(name).addError(name, message: "is invalid") }
        return copy.putChange(name, value: value(values))
    }

    /// Replace an earlier cast or put of the embed `name` with an "is invalid" error.
    private func invalidEmbed(_ name: String) -> Changeset<T> {
        var copy = deleteChange(name)
        copy.replaceAssociation(name)
        return copy.addError(name, message: "is invalid")
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
        for (_, write) in associationWrites { record = try await write(record, repo) }
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

/// The primary key of a record, hashable and bound.
private func recordKey<S: Schema>(_ record: S) -> (key: AnyHashable, data: PostgresData)? {
    SchemaRegistry.extractMetadata(from: S.self).primaryKeyField.flatMap {
        PreloadQuery<S>.extractPrimaryKeyPair(from: record, fieldName: $0)
    }
}

/// The join table of a many-to-many relationship, and its columns referring to each side.
struct Junction: Sendable {
    let table: String
    let parentColumn: String
    let relatedColumn: String

    /// Insert the join row, unless it exists: a preload may have left it out, or `related`
    /// may appear twice.
    func link(_ parent: any PrimaryKeyType, _ related: any PrimaryKeyType, using repo: any Repo) async throws {
        let matches = "\(parentColumn.quoted) = $1 AND \(relatedColumn.quoted) = $2"
        _ = try await repo.executeRawQuery(
            sql: "INSERT INTO \(table.quoted) (\(parentColumn.quoted), \(relatedColumn.quoted)) SELECT $1, $2 WHERE NOT EXISTS (SELECT 1 FROM \(table.quoted) WHERE \(matches))",
            parameters: [parent.toPostgresData(), related.toPostgresData()]
        )
    }

    func unlink(_ parent: any PrimaryKeyType, _ related: any PrimaryKeyType, using repo: any Repo) async throws {
        _ = try await repo.executeRawQuery(
            sql: "DELETE FROM \(table.quoted) WHERE \(parentColumn.quoted) = $1 AND \(relatedColumn.quoted) = $2",
            parameters: [parent.toPostgresData(), related.toPostgresData()]
        )
    }
}
