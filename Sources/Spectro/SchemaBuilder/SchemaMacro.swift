/// Generates a complete `Schema` + `SchemaBuilder` + `Encodable` conformance for a struct.
///
/// Annotate your struct with `@Schema("table_name")` and the macro generates:
/// - `static let tableName` — from the string argument
/// - `static var softDeleteColumn` — the database column of an `@SoftDelete` field, if present
/// - `init()` — default initializer with type-appropriate defaults
/// - `init(column params...)` — convenience initializer for `@Column`/`@ForeignKey` properties
/// - `SchemaBuilder.build(from:)` — row-mapping from `[String: Any]`
/// - `Encodable` conformance — `CodingKeys` enum and `encode(to:)` method
///
/// The struct automatically conforms to `Schema`, `SchemaBuilder`, and `Encodable` —
/// no manual protocol conformance needed.
///
/// ## Encodable Behavior
///
/// - All `@Column`, `@ID`, `@Timestamp`, `@SoftDelete`, `@ForeignKey` properties are encoded
/// - JSON keys use `snake_case` conversion of the Swift property name
/// - `@Column("custom_name")` overrides produce the custom name as the JSON key
/// - Relationship properties (`@HasMany`, `@HasOne`, `@BelongsTo`, `@ManyToMany`)
///   encode only when loaded; the key is omitted when the relation is `.notLoaded`
///
/// To opt out of `Encodable` generation:
/// ```swift
/// @Schema("secrets", encodable: false)
/// ```
///
/// ## Usage
///
/// ```swift
/// @Schema("users")
/// struct User {
///     @ID var id: UUID
///     @Column var name: String
///     @Column var email: String
///     @Column var bio: String?
///     @Timestamp var createdAt: Date
/// }
/// ```
///
/// Relationship wrappers (`@HasMany`, `@HasOne`, `@BelongsTo`) are handled in
/// `init()` with sensible defaults but are not included as parameters in the
/// convenience initializer, nor in `build(from:)`.
///
/// If you provide your own `tableName`, `softDeleteColumn`, or `init()` in the struct body, the macro
/// skips generating those members.
@attached(member, names: named(tableName), named(softDeleteColumn), named(init), named(_keyPathToColumn))
@attached(extension, conformances: Schema, SchemaBuilder, Encodable, names: named(build), named(CodingKeys), named(encode))
public macro Schema(_ tableName: String) = #externalMacro(module: "SpectroMacros", type: "SchemaMacro")

@attached(member, names: named(tableName), named(softDeleteColumn), named(init), named(_keyPathToColumn))
@attached(extension, conformances: Schema, SchemaBuilder, Encodable, names: named(build), named(CodingKeys), named(encode))
public macro Schema(_ tableName: String, encodable: Bool) = #externalMacro(module: "SpectroMacros", type: "SchemaMacro")

/// Generates a schema without a table, stored as `jsonb` in a column of another schema, like
/// Ecto's `embedded_schema`.
///
/// ```swift
/// @EmbeddedSchema
/// struct Address {
///     @Column var street: String
///     @Column var city: String
/// }
///
/// @Schema("users")
/// struct User {
///     @ID var id: UUID
///     @Column var address: Address?       // a jsonb column
///     @Column var phones: [Phone] = []     // a jsonb[] column, Ecto's {:array, :map}
/// }
/// ```
///
/// The struct conforms to `Schema` and `JSONBValue`: changesets cast and validate it, alone, as
/// for a form, or through `Changeset.castEmbed` in its parent's. An `@ID` is optional; with one,
/// new values get a fresh key and `castEmbed` matches params to values by it. Properties, which
/// must be `Codable`, are stored under their column names, such as `postal_code`, with `nil` as
/// null; a missing key keeps the property's default, so adding a property needs no data
/// migration. `cast` accepts only values of the struct, not params. The struct has no table to
/// query.
@attached(member, names: named(tableName), named(softDeleteColumn), named(init), named(_keyPathToColumn))
@attached(extension, conformances: Schema, SchemaBuilder, JSONBValue, names: named(build), named(CodingKeys), named(encode), named(init), named(cast))
public macro EmbeddedSchema() = #externalMacro(module: "SpectroMacros", type: "SchemaMacro")
