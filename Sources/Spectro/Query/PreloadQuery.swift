import Foundation
@preconcurrency import PostgresNIO
import SpectroCommon

/// A query that returns models: a `Query` or a `PreloadQuery`.
///
/// A preload's customization closure returns one, so it can filter and order the
/// related records or preload their own relationships.
public protocol ModelQuery<Model>: Sendable {
    associatedtype Model: Schema
    func all() async throws -> [Model]
}

extension Query: ModelQuery {}
extension PreloadQuery: ModelQuery {}

/// Customizes the query that loads a relationship's records, like Ecto's preload queries.
public typealias PreloadCustomization<Related: Schema> = @Sendable (Query<Related>) -> any ModelQuery<Related>

/// Query that batch-loads relationships for a set of parent entities,
/// eliminating the N+1 query problem.
///
/// ## Usage
///
/// ```swift
/// // Load users with their posts in two queries total (not N+1)
/// let users = try await repo.query(User.self)
///     .where { $0.isActive == true }
///     .preload(\.$posts)            // FK inferred: "userId"
///     .preload(\.$profile)          // FK inferred: "userId"
///     .all()
///
/// // Filter, order, and nest: one query per relationship, whatever the number of users.
/// let authors = try await repo.query(User.self)
///     .preload(\.$posts) { posts in
///         posts.where { $0.published == true }
///             .orderBy({ $0.createdAt }, .desc)
///             .preload(\.$comments)
///     }
///     .all()
///
/// // Override FK when it doesn't follow convention:
/// let posts = try await repo.query(Post.self)
///     .preload(\.$author, foreignKey: "authorId")
///     .all()
/// ```
///
/// A limit in a customization applies to all parents together, not to each parent.
public struct PreloadQuery<T: Schema>: Sendable {
    internal let baseQuery: Query<T>
    // Each preloader is a @Sendable closure that takes the current entities
    // and a repo, and returns updated entities with the relationship filled in.
    internal let preloaders: [@Sendable ([T], any Repo) async throws -> [T]]

    internal init(
        baseQuery: Query<T>,
        preloaders: [@Sendable ([T], any Repo) async throws -> [T]]
    ) {
        self.baseQuery = baseQuery
        self.preloaders = preloaders
    }

    // MARK: - Chaining Additional Preloads

    /// Also load a has-many or many-to-many relationship. `customize` adjusts the query
    /// that loads the related records.
    public func preload<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery, preloaders: preloaders + [Self.preloader(keyPath, foreignKey: foreignKey, customize)])
    }

    /// Also load a has-one or belongs-to relationship. `customize` adjusts the query
    /// that loads the related records.
    public func preload<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String? = nil,
        _ customize: PreloadCustomization<Related>? = nil
    ) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery, preloaders: preloaders + [Self.preloader(keyPath, foreignKey: foreignKey, customize)])
    }

    // MARK: - Query Chaining

    public func `where`(_ condition: (QueryBuilder<T>) -> QueryCondition) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery.where(condition), preloaders: preloaders)
    }

    public func orderBy<V>(_ field: (QueryBuilder<T>) -> QueryField<V>, _ direction: OrderDirection = .asc) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery.orderBy(field, direction), preloaders: preloaders)
    }

    public func limit(_ count: Int) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery.limit(count), preloaders: preloaders)
    }

    public func offset(_ count: Int) -> PreloadQuery<T> {
        PreloadQuery(baseQuery: baseQuery.offset(count), preloaders: preloaders)
    }

    // MARK: - Execution

    public func all() async throws -> [T] {
        let entities = try await baseQuery.all()
        guard !entities.isEmpty, !preloaders.isEmpty else { return entities }
        let repo: any Repo
        if let connection = baseQuery.executor as? DatabaseConnection {
            repo = GenericDatabaseRepo(connection: connection)
        } else if let context = baseQuery.executor as? TransactionContext {
            repo = TransactionRepo(context: context)
        } else {
            return entities
        }
        var result = entities
        for preloader in preloaders {
            result = try await preloader(result, repo)
        }
        return result
    }

    public func first() async throws -> T? {
        try await limit(1).all().first
    }

    // MARK: - Preloader Factory Methods

    // MARK: KeyPath Boxing for Sendable Closures
    //
    // `WritableKeyPath` has `@unchecked Sendable` conformance in Swift's stdlib,
    // but Swift 6.x's strict concurrency checker doesn't always propagate this
    // through generic type parameters in closure captures.
    //
    // `KPBox` wraps the keypath so closures can capture it without diagnostics.
    // This is safe because:
    // 1. `WritableKeyPath` is documented as Sendable by Apple
    // 2. The keypath itself is immutable after creation
    // 3. We only read the keypath, never mutate it
    //
    // This workaround can be removed when Swift's Sendable inference improves.
    private struct KPBox<Root, Value>: @unchecked Sendable {
        let value: WritableKeyPath<Root, Value>
    }

    /// Creates a preloader for a has-many or many-to-many relationship.
    static func preloader<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String?,
        _ customize: PreloadCustomization<Related>?
    ) -> @Sendable ([T], any Repo) async throws -> [T] {
        let relInfo = T()[keyPath: keyPath].relationshipInfo
        let box = KPBox(value: keyPath)
        guard relInfo.kind == .manyToMany else {
            // FK is on the *related* table: `SELECT * FROM related WHERE fk IN (parentIds)`.
            let fk = foreignKey ?? conventionalForeignKey(for: T.self)
            return { entities, repo in
                try await batchLoadHasMany(entities: entities, keyPath: box.value, foreignKey: fk, repo: repo, customize: customize)
            }
        }
        // Queries the junction table, then the related table, grouping results back to parents.
        let junctionTable = relInfo.junctionTable ?? ""
        let parentFK = (relInfo.parentForeignKey?.isEmpty == false)
            ? relInfo.parentForeignKey!
            : conventionalForeignKey(for: T.self)
        let relatedFK = (relInfo.relatedForeignKey?.isEmpty == false)
            ? relInfo.relatedForeignKey!
            : conventionalForeignKey(for: Related.self)
        return { entities, repo in
            try await batchLoadManyToMany(
                entities: entities,
                keyPath: box.value,
                junctionTable: junctionTable,
                parentFK: parentFK,
                relatedFK: relatedFK,
                repo: repo,
                customize: customize
            )
        }
    }

    /// Creates a preloader for a has-one or belongs-to relationship.
    /// Reads `RelationshipInfo.kind` from a temporary instance to distinguish them.
    static func preloader<Related: Schema>(
        _ keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String?,
        _ customize: PreloadCustomization<Related>?
    ) -> @Sendable ([T], any Repo) async throws -> [T] {
        let kind = T()[keyPath: keyPath].relationshipInfo.kind
        let box = KPBox(value: keyPath)

        if kind == .belongsTo {
            let fk = foreignKey ?? conventionalForeignKey(for: Related.self)
            return { entities, repo in
                try await batchLoadBelongsTo(entities: entities, keyPath: box.value, foreignKey: fk, repo: repo, customize: customize)
            }
        }
        let fk = foreignKey ?? conventionalForeignKey(for: T.self)
        return { entities, repo in
            try await batchLoadHasOne(entities: entities, keyPath: box.value, foreignKey: fk, repo: repo, customize: customize)
        }
    }

    // MARK: - Batch Loading

    private static func batchLoadManyToMany<Related: Schema>(
        entities: [T],
        keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        junctionTable: String,
        parentFK: String,
        relatedFK: String,
        repo: any Repo,
        customize: PreloadCustomization<Related>?
    ) async throws -> [T] {
        let metadata = await SchemaRegistry.shared.register(T.self)
        let relatedMeta = await SchemaRegistry.shared.register(Related.self)
        guard let pkField = metadata.primaryKeyField,
              let parentKeyType = metadata.fields.first(where: \.isPrimaryKey)?.valueType,
              let relPK = relatedMeta.primaryKeyField,
              let relatedKeyType = relatedMeta.fields.first(where: \.isPrimaryKey)?.valueType
        else { return entities }

        var parentKeys: [AnyHashable] = []
        var parentParams: [PostgresData] = []
        for entity in entities {
            if let pair = extractPrimaryKeyPair(from: entity, fieldName: pkField) {
                parentKeys.append(pair.key)
                parentParams.append(pair.data)
            }
        }
        guard !parentKeys.isEmpty else { return entities }

        // Step 1: Query junction table for all rows matching parent IDs
        let junctionRows = try await batchFetchJunction(
            junctionTable: junctionTable,
            whereColumn: parentFK.snakeCase(),
            relatedColumn: relatedFK.snakeCase(),
            keyTypes: (parentKeyType, relatedKeyType),
            inParams: parentParams,
            repo: repo
        )

        // Build parent → [relatedId] mapping and collect unique related IDs
        var parentToRelatedIds: [AnyHashable: [AnyHashable]] = [:]
        var uniqueRelatedKeys = Set<AnyHashable>()
        var uniqueRelatedParams: [PostgresData] = []
        for (pId, rId, rData) in junctionRows {
            parentToRelatedIds[pId, default: []].append(rId)
            if uniqueRelatedKeys.insert(rId).inserted {
                uniqueRelatedParams.append(rData)
            }
        }

        guard !uniqueRelatedKeys.isEmpty else {
            // No junction rows found — return entities with empty arrays
            return entities.map { entity in
                var e = entity
                e[keyPath: keyPath] = SpectroLazyRelation(
                    loaded: [],
                    relationshipInfo: entity[keyPath: keyPath].relationshipInfo
                )
                return e
            }
        }

        // Step 2: Fetch related entities by their PK
        let relatedEntities: [Related] = try await batchFetch(
            relatedType: Related.self,
            whereField: relPK,
            inParams: uniqueRelatedParams,
            repo: repo,
            customize: customize
        )

        // Keep the related query's order, which a customization may set.
        var relatedIndex: [AnyHashable: (position: Int, entity: Related)] = [:]
        for (position, r) in relatedEntities.enumerated() {
            if let pair = extractPrimaryKeyPair(from: r, fieldName: relPK) {
                relatedIndex[pair.key] = (position, r)
            }
        }

        return entities.map { entity in
            var e = entity
            let parentId = extractPrimaryKeyPair(from: entity, fieldName: pkField)?.key
            let relatedIds = parentId.flatMap { parentToRelatedIds[$0] } ?? []
            let loaded = relatedIds.compactMap { relatedIndex[$0] }.sorted { $0.position < $1.position }.map(\.entity)
            e[keyPath: keyPath] = SpectroLazyRelation(
                loaded: loaded,
                relationshipInfo: entity[keyPath: keyPath].relationshipInfo
            )
            return e
        }
    }

    private static func batchLoadHasMany<Related: Schema>(
        entities: [T],
        keyPath: WritableKeyPath<T, SpectroLazyRelation<[Related]>>,
        foreignKey: String,
        repo: any Repo,
        customize: PreloadCustomization<Related>?
    ) async throws -> [T] {
        let foreignKey = await propertyName(foreignKey, in: Related.self)
        let metadata = await SchemaRegistry.shared.register(T.self)
        guard let pkField = metadata.primaryKeyField else { return entities }

        var parentParams: [PostgresData] = []
        for entity in entities {
            if let pair = extractPrimaryKeyPair(from: entity, fieldName: pkField) {
                parentParams.append(pair.data)
            }
        }
        guard !parentParams.isEmpty else { return entities }

        let related: [Related] = try await batchFetch(
            relatedType: Related.self,
            whereField: foreignKey,
            inParams: parentParams,
            repo: repo,
            customize: customize
        )

        var grouped: [AnyHashable: [Related]] = [:]
        for r in related {
            if let pair = extractPrimaryKeyPair(from: r, fieldName: foreignKey) {
                grouped[pair.key, default: []].append(r)
            }
        }

        return entities.map { entity in
            var e = entity
            let parentId = extractPrimaryKeyPair(from: entity, fieldName: pkField)?.key
            let loaded = parentId.flatMap { grouped[$0] } ?? []
            e[keyPath: keyPath] = SpectroLazyRelation(
                loaded: loaded,
                relationshipInfo: entity[keyPath: keyPath].relationshipInfo
            )
            return e
        }
    }

    private static func batchLoadHasOne<Related: Schema>(
        entities: [T],
        keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String,
        repo: any Repo,
        customize: PreloadCustomization<Related>?
    ) async throws -> [T] {
        let foreignKey = await propertyName(foreignKey, in: Related.self)
        let metadata = await SchemaRegistry.shared.register(T.self)
        guard let pkField = metadata.primaryKeyField else { return entities }

        var parentParams: [PostgresData] = []
        for entity in entities {
            if let pair = extractPrimaryKeyPair(from: entity, fieldName: pkField) {
                parentParams.append(pair.data)
            }
        }
        guard !parentParams.isEmpty else { return entities }

        let related: [Related] = try await batchFetch(
            relatedType: Related.self,
            whereField: foreignKey,
            inParams: parentParams,
            repo: repo,
            customize: customize
        )

        var grouped: [AnyHashable: Related] = [:]
        for r in related {
            if let pair = extractPrimaryKeyPair(from: r, fieldName: foreignKey),
               grouped[pair.key] == nil {
                grouped[pair.key] = r
            }
        }

        return entities.map { entity in
            var e = entity
            let parentId = extractPrimaryKeyPair(from: entity, fieldName: pkField)?.key
            let loaded: Related? = parentId.flatMap { grouped[$0] }
            e[keyPath: keyPath] = SpectroLazyRelation(
                loaded: loaded,
                relationshipInfo: entity[keyPath: keyPath].relationshipInfo
            )
            return e
        }
    }

    private static func batchLoadBelongsTo<Related: Schema>(
        entities: [T],
        keyPath: WritableKeyPath<T, SpectroLazyRelation<Related?>>,
        foreignKey: String,      // Column on T that holds the related entity's ID
        repo: any Repo,
        customize: PreloadCustomization<Related>?
    ) async throws -> [T] {
        let foreignKey = await propertyName(foreignKey, in: T.self)
        var seen = Set<AnyHashable>()
        var relatedParams: [PostgresData] = []
        for entity in entities {
            if let pair = extractPrimaryKeyPair(from: entity, fieldName: foreignKey),
               seen.insert(pair.key).inserted {
                relatedParams.append(pair.data)
            }
        }
        guard !relatedParams.isEmpty else { return entities }

        // Fetch related by primary key
        let relatedMeta = await SchemaRegistry.shared.register(Related.self)
        guard let relPK = relatedMeta.primaryKeyField else { return entities }

        let related: [Related] = try await batchFetch(
            relatedType: Related.self,
            whereField: relPK,
            inParams: relatedParams,
            repo: repo,
            customize: customize
        )

        var index: [AnyHashable: Related] = [:]
        for r in related {
            if let pair = extractPrimaryKeyPair(from: r, fieldName: relPK) { index[pair.key] = r }
        }

        return entities.map { entity in
            var e = entity
            let fkVal = extractPrimaryKeyPair(from: entity, fieldName: foreignKey)?.key
            let loaded: Related? = fkVal.flatMap { index[$0] }
            e[keyPath: keyPath] = SpectroLazyRelation(
                loaded: loaded,
                relationshipInfo: entity[keyPath: keyPath].relationshipInfo
            )
            return e
        }
    }

    // MARK: - Shared Query Helper

    /// Execute `SELECT * FROM table WHERE field IN (params)`, customized by `customize`.
    /// `field` is a Swift property name of `Related`, or a column name.
    /// Accepts pre-built `[PostgresData]` so callers can pass any PK type.
    private static func batchFetch<Related: Schema>(
        relatedType: Related.Type,
        whereField field: String,
        inParams: [PostgresData],
        repo: any Repo,
        customize: PreloadCustomization<Related>?
    ) async throws -> [Related] {
        guard !inParams.isEmpty else { return [] }
        let metadata = await SchemaRegistry.shared.register(Related.self)
        let column = metadata.fields.first { $0.name == field }?.databaseName ?? field.snakeCase()
        let placeholders = Array(repeating: "?", count: inParams.count).joined(separator: ", ")
        // Qualified, so a customization may join other tables.
        let condition = QueryCondition(
            sql: "\(Related.tableName.quoted).\(column.quoted) IN (\(placeholders))",
            parameters: inParams
        )
        let query = repo.query(relatedType).where { _ in condition }
        guard let customize else { return try await query.all() }
        return try await customize(query).all()
    }

    /// Execute `SELECT parentFK, relatedFK FROM junction WHERE parentFK IN (params)`.
    /// Returns an array of (parentKey, relatedKey, relatedData) tuples from the junction table.
    /// The third element carries the `PostgresData` for the related ID so callers can pass it
    /// directly to `batchFetch` without lossy conversions.
    private static func batchFetchJunction(
        junctionTable: String,
        whereColumn: String,
        relatedColumn: String,
        keyTypes: (parent: any DatabaseValue.Type, related: any DatabaseValue.Type),
        inParams: [PostgresData],
        repo: any Repo
    ) async throws -> [(AnyHashable, AnyHashable, PostgresData)] {
        guard !inParams.isEmpty else { return [] }
        let placeholders = (1...inParams.count).map { "$\($0)" }.joined(separator: ", ")
        let sql = """
            SELECT "\(whereColumn)", "\(relatedColumn)" FROM "\(junctionTable)" WHERE "\(whereColumn)" IN (\(placeholders))
            """

        let rows = try await repo.executeRawQuery(
            sql: sql,
            parameters: inParams
        )

        var result: [(AnyHashable, AnyHashable, PostgresData)] = []
        for row in rows {
            let ra = row.makeRandomAccess()
            let parentData = ra[data: whereColumn]
            let relatedData = ra[data: relatedColumn]
            // Decode as the key types, so keys hash like the entities' own keys.
            if let parentKey = hashableKey(parentData, as: keyTypes.parent),
               let relatedKey = hashableKey(relatedData, as: keyTypes.related) {
                result.append((parentKey, relatedKey, relatedData))
            }
        }
        return result
    }

    private static func hashableKey(_ data: PostgresData, as type: any DatabaseValue.Type) -> AnyHashable? {
        (type.fromPostgresData(data) as? any Hashable).map { AnyHashable($0) }
    }

    /// The Swift property for `field`, given as a property name or a database column.
    private static func propertyName<S: Schema>(_ field: String, in type: S.Type) async -> String {
        let fields = await SchemaRegistry.shared.register(type).fields
        return (fields.first { $0.name == field } ?? fields.first { $0.databaseName == field })?.name ?? field
    }

    // MARK: - Helpers

    /// Extract a key from an `@ID`, `@ForeignKey`, or `@Column` property, or a bare stored
    /// property, by name. A NULL key, such as a nil nullable foreign key, returns `nil`.
    /// Returns both the hashable key (for dictionary grouping) and PostgresData (for SQL params).
    static func extractPrimaryKeyPair<S: Schema>(from entity: S, fieldName: String) -> (key: AnyHashable, data: PostgresData)? {
        for child in Mirror(reflecting: entity).children {
            guard let label = child.label else { continue }
            let name = label.hasPrefix("_") ? String(label.dropFirst()) : label
            guard name == fieldName else { continue }
            if let v = child.value as? any PrimaryKeyWrapperProtocol {
                return (v.primaryKeyHashable, v.primaryKeyPostgresData)
            }
            if let v = child.value as? any ForeignKeyWrapperProtocol {
                // A nil foreign key refers to no record.
                let data = v.foreignKeyPostgresData
                return data.value == nil ? nil : (v.foreignKeyHashable, data)
            }
            var value = Mirror(reflecting: child.value).children.first { $0.label == "wrappedValue" }?.value ?? child.value
            let optional = Mirror(reflecting: value)
            if optional.displayStyle == .optional {
                guard let wrapped = optional.children.first?.value else { return nil }
                value = wrapped
            }
            guard let key = value as? any DatabaseValue & Hashable, let data = try? key.toPostgresData() else { return nil }
            return (AnyHashable(key), data)
        }
        return nil
    }

    /// Convention-based FK: "User" → "userId", "BlogPost" → "blogPostId".
    static func conventionalForeignKey(for type: any Schema.Type) -> String {
        let name = String(describing: type)
        return name.prefix(1).lowercased() + name.dropFirst() + "Id"
    }
}
