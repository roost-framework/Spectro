# Schemas and changesets

Map stored fields explicitly and validate incoming values before persistence.

## Overview

### Describe stored fields

```swift
import Foundation
import Spectro

@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @Column("email_address") var email: String
    @Column var bio: String?
    @Timestamp var createdAt: Date
    @SoftDelete var deletedAt: Date?
}
```

``ID`` supports ``PrimaryKeyType`` values such as `UUID`, `Int`, and `String`. ``Column`` maps a stored field and optionally overrides its database name, which query builders, inserts, and decoding all use; `column(for:)` returns a key path's database column. ``Timestamp`` holds a date field. The schema macro preserves those mappings when building rows and encoding JSON.

``SoftDelete`` opts the model into deletion timestamps and default filtering. Add the corresponding nullable database column through a migration. Queries exclude soft-deleted rows by default, including rows of joined tables, and `update` treats them as missing. `.withDeleted()` and `get(_:id:withDeleted:)` include them, and `restore(_:id:)` clears the deletion timestamp. Schema declarations describe models, while migrations own the database's historical structure.

The macro also has an `encodable: false` form when you need to provide your own encoding implementation.

### Store PostgreSQL types

```swift
enum Status: String, Codable, DatabaseValue { case draft, published }
struct Address: Codable, JSONBValue { var city: String }

@Schema("listings")
struct Listing {
    @ID var id: UUID
    @Column var price: Decimal
    @Column var status: Status = .draft
    @Column var tags: [String]
    @Column var address: Address = Address(city: "")
    @Column var photo: Data
}
```

``Column`` stores any ``DatabaseValue``, Spectro's counterpart of `Ecto.Type`: the scalar types above, `Decimal` as `numeric`, `Data` as `bytea`, arrays as PostgreSQL arrays, `[String: Value]` dictionaries and ``JSONBValue`` types as `jsonb`, raw-value enums as their raw value, and `Optional` of any of them as a nullable column. A `String` raw value fits text, varchar, and PostgreSQL enum columns. Changesets cast input to these types, such as `"12.50"` to a `Decimal` or a JSON object to an `Address`. Dates in `jsonb` values are stored as ISO 8601 strings with milliseconds, as Ecto does. Conform another type by implementing `toPostgresData()` and `fromPostgresData(_:)`.

### Cast permitted input

```swift
let params: [String: any Sendable] = [
    "name": "Alice",
    "email": "alice@example.com",
    "admin": true
]

let changeset = Changeset<User>.cast(
    nil,
    params: params,
    permitted: ["name", "email", "bio"]
)
.validateRequired(["name", "email"])
.validateLength("name", min: 2, max: 100)
.validateFormat("email", pattern: #"^.+@.+\..+$"#)

let user = try await repo.insert(changeset)
```

``Changeset`` is immutable: casting and each validator return a new value. Unknown or unpermitted fields, such as `admin` above, are ignored. Invalid field types are recorded as errors. Use Swift property names in changesets; repositories honor custom SQL column mappings such as `email_address`.

Inspect `isValid` and `errors` before presenting validation feedback. ``ChangesetErrors`` provides a serializable error representation. Database constraints remain necessary for invariants such as uniqueness under concurrent writes.

### Map database constraints to field errors

```swift
let changeset = Changeset<User>.cast(nil,
    params: params, permitted: ["name", "email"])
    .uniqueConstraint("email", name: "users_email_key", message: "is already registered")

do {
    _ = try await repo.insert(changeset)
} catch let error as SpectroError {
    guard let fields = error.fieldErrors else { throw error }
    let response = try JSONEncoder().encode(fields)
}
```

Declare `uniqueConstraint`, `foreignKeyConstraint`, or `checkConstraint` with the exact database constraint/index name and a Swift property name. A matching name, SQLSTATE, and reported table converts an insert/update failure to `SpectroError.changesetFailed`, retaining the original database error. The expected table defaults to the model's table; a missing or different reported table leaves the original error intact. This avoids attributing another table's trigger failure to this model. `fieldErrors` and `serverError` unwrap transaction failures too. Unregistered database failures and existing local validation errors keep their original behavior.

For a partitioned table, PostgreSQL may report the physical partition. Explicitly accept that origin with, for example, `.checkConstraint("amount", name: "amount_positive", onTable: "orders_2026")`. Declare each accepted partition separately with its exact reported constraint name. Only accept origins that belong to the field being validated.

Declarations do not create constraints or pre-check the database. A failed write still aborts its transaction; use a savepoint when recovering locally before continuing with further writes.

Declare the same composite constraint on multiple fields to attach an error to each. A constraint deferred until commit remains a server error, since no individual changeset write is active when it fails.

### Update a record

```swift
let changeset = Changeset<User>.cast(
    user,
    params: ["name": "Alice Martin"],
    permitted: ["name"]
)
.validateRequired(["name"])

let updated = try await repo.update(changeset)
```

Pass the existing record as `data` for updates and `nil` for inserts. Both ``GenericDatabaseRepo`` and ``TransactionRepo`` accept changesets, so the same validation pipeline works inside a transaction.

`castAssoc(_:params:foreignKey:onReplace:with:)` casts nested params into a has-many, has-one, or many-to-many relationship, written with the record in one transaction, and `putAssoc(_:_:foreignKey:onReplace:)` sets a relationship to stored records or to changesets, like Ecto's `put_assoc`. ``Changeset/prepareChanges(_:)`` runs a function in the write's transaction just before it.

``EmbeddedSchema()`` declares a schema without a table, like Ecto's `embedded_schema`, stored as `jsonb` in a column of another schema, or as `jsonb[]` for a list:

```swift
@EmbeddedSchema
struct Address {
    @Column var city: String
}

let changeset = Changeset.cast(user, params: ["address": ["city": "Oslo"]], permitted: [])
    .castEmbed(\.address) { address, params in
        Changeset.cast(address, params: params, permitted: ["city"]).validateRequired(["city"])
    }
```

`castEmbed(_:with:)` casts a field's nested params, from those given to `cast`, into an embedded value or list, like Ecto's `cast_embed`; without params for the field, its value stays as it is. `putEmbed(_:_:)` sets values or changesets, like Ecto's `put_embed`. The values are changes of the field, written with the record, and their errors join the record's as `"address.city"` or `"phones[1].number"`. On its own, an embedded schema validates input without a table, such as a form, and ``Changeset/applyToInstance()`` returns the values of a valid changeset.

Every field name also has a key path form, such as `Changeset.cast(nil, params: params, permitting: \.name, \.email)`, `.validateRequired(\.name)`, `.validateInclusion(\.role, in: [.member])`, and `.putChange(\.isActive, true)`, so a renamed property fails to compile and values have the field's type.

`optimisticLock(_:)` guards an update against concurrent ones: it increments an integer version field, `lockVersion` by default, and throws `SpectroError.staleRecord` when the row no longer holds the loaded version.

For related models and efficient loading, continue with <doc:QueriesAndRelationships>.
