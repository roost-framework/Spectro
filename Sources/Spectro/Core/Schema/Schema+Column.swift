import SpectroCommon

extension Schema {
    /// The unquoted database column that stores the property at `keyPath`.
    ///
    /// Applies the snake_case convention and the column names given to `@Column` and `@ForeignKey`:
    ///
    /// ```swift
    /// @Schema("users")
    /// struct User {
    ///     @ID var id: UUID
    ///     @Column("display_name") var name: String
    ///     @ForeignKey var teamId: UUID
    /// }
    ///
    /// User.column(for: \.name)    // "display_name"
    /// User.column(for: \.teamId)  // "team_id"
    /// ```
    ///
    /// Use this instead of reading `_keyPathToColumn`, which holds Swift property names, not columns.
    /// A key path that is not a stored column, such as a relationship or a computed property,
    /// returns its snake_cased property name, as query builders do; no column is checked.
    public static func column<V>(for keyPath: KeyPath<Self, V>) -> String {
        let property = extractFieldName(from: keyPath, schema: Self.self)
        let field = SchemaRegistry.extractMetadata(from: Self.self).fields.first { $0.name == property }
        return field?.databaseName ?? property.snakeCase()
    }
}
