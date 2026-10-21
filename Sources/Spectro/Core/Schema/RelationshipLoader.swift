import Foundation
@preconcurrency import PostgresNIO

/// Handles loading relationships for individual schema instances.
///
/// For batch loading (N+1 prevention), use `Query.preload(_:)` instead.
public struct RelationshipLoader {

    // MARK: - Has-Many

    public static func loadHasMany<Parent: Schema, Child: Schema>(
        for parent: Parent,
        relationship: String,
        childType: Child.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> [Child] {
        let parentMetadata = await SchemaRegistry.shared.register(Parent.self)
        guard let pkField = parentMetadata.primaryKeyField else {
            throw SpectroError.invalidSchema(reason: "Schema \(Parent.self) has no primary key")
        }
        guard let pkData = extractPrimaryKeyPair(from: parent, fieldName: pkField)?.data else {
            throw SpectroError.missingRequiredField("Primary key '\(pkField)' not found in \(Parent.self)")
        }
        let condition = QueryCondition(
            sql: "\"\(foreignKey.snakeCase())\" = ?",
            parameters: [pkData]
        )
        return try await repo.query(childType).where { _ in condition }.all()
    }

    // MARK: - Has-One

    public static func loadHasOne<Parent: Schema, Child: Schema>(
        for parent: Parent,
        relationship: String,
        childType: Child.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> Child? {
        try await loadHasMany(
            for: parent, relationship: relationship,
            childType: childType, foreignKey: foreignKey, using: repo
        ).first
    }

    // MARK: - Belongs-To

    public static func loadBelongsTo<Child: Schema, Parent: Schema>(
        for child: Child,
        relationship: String,
        parentType: Parent.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> Parent? {
        guard let fkData = extractPrimaryKeyPair(from: child, fieldName: foreignKey)?.data else {
            // A nil foreign key refers to no parent.
            if await SchemaRegistry.shared.register(Child.self).fields.contains(where: { $0.name == foreignKey }) { return nil }
            throw SpectroError.missingRequiredField("FK '\(foreignKey)' not found in \(Child.self)")
        }
        let parentMeta = await SchemaRegistry.shared.register(parentType)
        let pkColumn = (parentMeta.primaryKeyField ?? "id").snakeCase()
        let condition = QueryCondition(
            sql: "\"\(pkColumn)\" = ?",
            parameters: [fkData]
        )
        return try await repo.query(parentType).where { _ in condition }.first()
    }

    // MARK: - Primary Key Extraction

    static func extractUUID<T: Schema>(from instance: T, fieldName: String) -> UUID? {
        PreloadQuery<T>.extractPrimaryKeyPair(from: instance, fieldName: fieldName)?.key.base as? UUID
    }

    static func extractPrimaryKeyPair<T: Schema>(from instance: T, fieldName: String) -> (key: AnyHashable, data: PostgresData)? {
        PreloadQuery<T>.extractPrimaryKeyPair(from: instance, fieldName: fieldName)
    }
}

// MARK: - Schema Extension API

extension Schema {
    public func loadHasMany<T: Schema>(
        _ type: T.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> [T] {
        try await RelationshipLoader.loadHasMany(
            for: self, relationship: String(describing: type),
            childType: type, foreignKey: foreignKey, using: repo
        )
    }

    public func loadHasOne<T: Schema>(
        _ type: T.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> T? {
        try await RelationshipLoader.loadHasOne(
            for: self, relationship: String(describing: type),
            childType: type, foreignKey: foreignKey, using: repo
        )
    }

    public func loadBelongsTo<T: Schema>(
        _ type: T.Type,
        foreignKey: String,
        using repo: GenericDatabaseRepo
    ) async throws -> T? {
        try await RelationshipLoader.loadBelongsTo(
            for: self, relationship: String(describing: type),
            parentType: type, foreignKey: foreignKey, using: repo
        )
    }
}
