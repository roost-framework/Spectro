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

For related models and efficient loading, continue with <doc:QueriesAndRelationships>.
