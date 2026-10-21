# Spectro

A Swift ORM for PostgreSQL, inspired by Elixir's Ecto. Property-wrapper schemas, a composable query builder, actor-based concurrency, and a CLI for migrations.

Browse guides and searchable API reference in the [documentation for the latest release](https://roost-framework.github.io/Spectro/docs/latest/), or [pick a release](https://roost-framework.github.io/Spectro/docs/). The [DocC documentation index](Documentation/README.md) covers this checkout; build it locally with `python3 scripts/build_docs.py`.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Documentation website](https://roost-framework.github.io/Spectro/docs/latest/)
- [Upgrading to 2.1](docs/UPGRADING-2.1.md)
- [Quick Start](#quick-start)
- [Schema Definition](#schema-definition)
- [CRUD Operations](#crud-operations)
- [Changesets](#changesets)
- [Query Builder](#query-builder)
- [Relationships](#relationships)
- [Transactions](#transactions)
- [Aggregates and GROUP BY](#aggregates-and-group-by)
- [JSON Encoding](#json-encoding)
- [Field Selection](#field-selection)
- [CLI Reference](#cli-reference)
- [Swift Migration Guide](docs/MIGRATIONS.md)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Development](#development)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Features

- **Property-wrapper schema definitions** -- `@ID`, `@Column`, `@Timestamp`, `@ForeignKey`, `@HasMany`, `@HasOne`, `@BelongsTo`, `@ManyToMany`
- **`@Schema` macro** -- generates `SchemaBuilder` and `Encodable` conformance at compile time (zero boilerplate)
- **Generic primary keys** -- `@ID<UUID>`, `@ID<Int>`, `@ID<String>` via the `PrimaryKeyType` protocol
- **Immutable query builder** -- `Query<T>` is a value type; every `.where()`, `.join()`, `.orderBy()` returns a new query
- **Type-safe aggregates** -- `.sum()`, `.avg()`, `.min()`, `.max()`, `.count()` with `GROUP BY` and `HAVING` support, and typed grouped projections with SQL expressions and window functions
- **PostgreSQL column types** -- `Decimal`, arrays, `jsonb`, `bytea`, raw-value enums, and your own types through `DatabaseValue`
- **SQL fragments** -- raw SQL in filters, ordering, and whole statements, with qualified fields and bound values, like Ecto's `fragment`
- **Query composition** -- `DISTINCT` and `DISTINCT ON`, `IN` and `EXISTS` subqueries, unions, intersections, differences, recursive queries, and column comparisons
- **Upsert and bulk insert** -- `ON CONFLICT` upserts, multi-row inserts that skip or update conflicting records, with automatic batching
- **Reloads and batches** -- reload records in one query, and read large results in primary key batches
- **Bulk updates, deletes, and row locks** -- `updateAll`, `deleteAll`, and `FOR UPDATE … SKIP LOCKED`
- **Relationship preloading** -- batch-loads `HasMany`, `HasOne`, `BelongsTo`, and `ManyToMany` relationships to prevent N+1 queries, nested and customized, on queries or loaded records
- **Query logging and observation** -- a debug log line and a `QueryEvent` per statement
- **Test sandbox** -- run tests in a transaction that is always rolled back, like Ecto's SQL sandbox
- **Transaction support** -- `READ COMMITTED`, `REPEATABLE READ`, or `SERIALIZABLE` isolation with automatic rollback; full CRUD and query builder available inside transactions via `QueryExecutor`
- **Changesets** -- permitted-field casting, validation, serializable errors, and insert/update inside transactions
- **Pagination and soft deletes** -- counted pages and opt-in deleted-record filtering
- **Actor-based connection pooling** -- built on SwiftNIO and PostgresKit
- **Plain SQL migrations** -- timestamped `.sql` files with `-- migrate:up` / `-- migrate:down` markers
- **Swift migrations** -- an optional `SpectroMigrations` DSL and a project-owned executable; see the [adoption and deployment guide](docs/MIGRATIONS.md)
- **CLI tool** -- `spectro` binary for database creation, migrations, and status
- **Swift 6 strict concurrency** -- full `Sendable` compliance across all types

## Requirements

- Swift 6.1+
- macOS 13+ or Linux
- PostgreSQL

## Installation

### As a Swift Package dependency

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.6.0")
```

The `CLI`, `RichTerminal`, and `Migrations` traits, on by default, bring the dependencies of the `spectro` command (ArgumentParser, plus Noora for colors, spinners, prompts, and tables) and `SpectroMigrations`. If you only use SpectroKit, disable them so SwiftPM never fetches ArgumentParser or Noora:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.6.0", traits: [])
```

To build the `spectro` command from your dependencies without Noora, as Roost does for `roost spectro`, enable only `CLI`; the command then prints plain text:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.6.0", traits: ["CLI"])
```

Then add `"SpectroKit"` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SpectroKit", package: "Spectro"),
    ]
)
```

### CLI via Mint

The `spectro` CLI is distributed via [Mint](https://github.com/yonaskolb/Mint):

```bash
mint install roost-framework/Spectro@2.6.0
```

Pin a version in your `Mintfile`:

```
roost-framework/Spectro@2.6.0
```

For existing applications, read the [2.1 upgrade guide](docs/UPGRADING-2.1.md) and [release notes](CHANGELOG.md). Applications updating from 1.x should also follow the [2.0 upgrade guide](docs/UPGRADING-2.0.md).

`spectro --version` reports the CLI version. For development against a local checkout, use the [local dependency and CLI setup](docs/MIGRATIONS.md#set-up-a-target).

## Quick Start

### 1. Define a schema

```swift
import Spectro

@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @Column var email: String
    @Timestamp var createdAt: Date
}
```

The `@Schema` macro generates `Schema`, `SchemaBuilder`, and `Encodable` conformance at compile time -- no manual `init()`, `build(from:)`, or `encode(to:)` required.

### 2. Connect and query

```swift
let spectro = try Spectro(
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "myapp_dev"
)

// Insert
let user = try await spectro.insert(User())

// Query
let repo = spectro.repository()
let activeUsers = try await repo.query(User.self)
    .where { $0.name == "John" }
    .orderBy({ $0.createdAt }, .desc)
    .limit(10)
    .all()

// Get by ID
let found = try await spectro.get(User.self, id: someUUID)

// Update
let updated = try await spectro.update(User.self, id: someUUID, changes: ["name": "Jane"])

// Delete
try await spectro.delete(User.self, id: someUUID)

// Shutdown (always call before releasing)
await spectro.shutdown()
```

## Schema Definition

### The @Schema macro

The `@Schema("table_name")` macro generates everything needed to map a struct to a database table:

- `static let tableName` from the string argument
- A default `init()` with type-appropriate defaults
- A convenience `init(column params...)` for `@Column` and `@ForeignKey` properties
- `SchemaBuilder.build(from:)` for row mapping
- `Encodable` conformance with `CodingKeys` and `encode(to:)` for JSON serialization

```swift
@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @Column var email: String
    @Column var bio: String?
    @Timestamp var createdAt: Date
}
```

### Property wrappers

| Wrapper | Purpose | Example |
|---------|---------|---------|
| `@ID<T>` | Primary key (UUID, Int, or String) | `@ID var id: UUID` |
| `@Column<T>` | Regular column, optional name override | `@Column("display_name") var name: String` |
| `@Timestamp` | Date column | `@Timestamp var createdAt: Date` |
| `@SoftDelete` | Nullable deletion timestamp | `@SoftDelete var deletedAt: Date?` |
| `@ForeignKey<T>` | Foreign key reference, optional name override | `@ForeignKey var userId: UUID` |
| `@HasMany<T>` | One-to-many relationship, optional FK binding | `@HasMany(foreignKey: "authorId") var posts: [Post]` |
| `@HasOne<T>` | One-to-one relationship | `@HasOne var profile: Profile?` |
| `@BelongsTo<T>` | Inverse of HasMany/HasOne | `@BelongsTo var user: User?` |
| `@ManyToMany<T>` | Many-to-many via junction table | `@ManyToMany(junctionTable: "user_tags") var tags: [Tag]` |

Add `@SoftDelete var deletedAt: Date?` and a matching nullable `TIMESTAMPTZ` database column to opt into soft deletes. `@Schema` generates the filtering metadata and timestamp mapping. `repo.delete` records the deletion time; normal reads and joins exclude deleted records, and `update` treats them as missing. `repo.query(User.self).withDeleted()` and `repo.get(User.self, id: id, withDeleted: true)` include them, and `repo.restore(User.self, id: id)` clears the deletion time. For manual schemas, implement `softDeleteColumn` with the database column name and decode the timestamp in `build(from:)`.

When upgrading from a version before 2.4.0, replace updates that clear the deletion timestamp with `restore`. Updates, including changeset updates, now throw `SpectroError.notFound` for deleted or unknown records; code that caught `databaseError` for an update without a matching row should handle `notFound` instead.

When upgrading to 2.6.0, add `changesetFailed` to any exhaustive switch over `SpectroError`. It carries structured field errors for declared database constraints, retains the underlying database error, and exposes PostgreSQL details through `serverError`.

### Generic primary keys

Primary keys are not limited to UUID. Any type conforming to `PrimaryKeyType` can be used. Built-in conformances: `UUID`, `Int`, `String`.

```swift
@Schema("articles")
struct Article {
    @ID var id: Int          // SERIAL primary key
    @Column var title: String
}

@Schema("slugs")
struct Slug {
    @ID var id: String       // TEXT primary key
    @Column var target: String
}
```

Foreign keys match the primary key type of the referenced table:

```swift
@Schema("comments")
struct Comment {
    @ID var id: UUID
    @Column var body: String
    @ForeignKey var articleId: Int    // references Article's Int PK
}
```

### Column name overrides

By default, Swift property names are converted to `snake_case` for column names. Override with a string argument:

```swift
@Schema("users")
struct User {
    @ID var id: UUID
    @Column("display_name") var name: String       // maps to "display_name" column
    @ForeignKey("team_ref_id") var teamId: UUID     // maps to "team_ref_id" column
}
```

Query builders, inserts, and decoding all use the overridden names. `User.column(for: \.name)` returns the database column for a key path (`"display_name"` here, `"team_ref_id"` for `\.teamId`).

### Column types

`@Column` stores any `DatabaseValue`, Spectro's counterpart of `Ecto.Type`. Besides `String`, `Int`, `Bool`, `UUID`, `Date`, `Double`, and `Float`:

```swift
enum Status: String, Codable, DatabaseValue { case draft, published }

struct Address: Codable, JSONBValue {
    var city: String
    var zip: String
}

@Schema("listings")
struct Listing {
    @ID var id: UUID
    @Column var price: Decimal                     // numeric
    @Column var status: Status = .draft            // text, varchar, or a PostgreSQL enum
    @Column var tags: [String]                     // text[]
    @Column var reviewerIds: [UUID]                // uuid[]
    @Column var address: Address = Address(city: "", zip: "")  // jsonb
    @Column var attributes: [String: String]       // jsonb
    @Column var photo: Data                        // bytea
    @Column var discount: Decimal?                 // nullable
}
```

Give enum and `JSONBValue` properties a default value, as above, since they have no `init()`. A value a property cannot represent, such as an enum label it lacks, fails decoding with `SpectroError.resultDecodingFailed`. `Decimal` holds 38 significant digits and cannot store NaN. Raw-value enums are stored as their raw value; arrays of them need a `text[]` column rather than an array of a PostgreSQL enum type. Changesets cast request input to these types: `"12.50"` to a `Decimal`, `"published"` to a `Status`, and a JSON object to an `Address`.

Conform other types by implementing `toPostgresData()` and `fromPostgresData(_:)`, and optionally `cast(_:)` for changesets and `postgresType` for arrays:

```swift
struct Cents: DatabaseValue {
    var amount: Int
    func toPostgresData() -> PostgresData { PostgresData(int: amount) }
    static func fromPostgresData(_ data: PostgresData) -> Cents? { data.int.map(Cents.init) }
}
```

### Manual schema definition

If you prefer not to use the macro, implement `Schema` and `SchemaBuilder` manually:

```swift
struct User: Schema, SchemaBuilder {
    static let tableName = "users"

    @ID var id: UUID
    @Column var name: String
    @Column var email: String
    @Timestamp var createdAt: Date

    init() {
        self.id = UUID()
        self.name = ""
        self.email = ""
        self.createdAt = Date()
    }

    static func build(from values: [String: Any]) -> User {
        var user = User()
        if let v = values["id"] as? UUID { user.id = v }
        if let v = values["name"] as? String { user.name = v }
        if let v = values["email"] as? String { user.email = v }
        if let v = values["createdAt"] as? Date { user.createdAt = v }
        return user
    }
}
```

## CRUD Operations

All CRUD is available on both the `Spectro` facade and the `GenericDatabaseRepo` actor (via `spectro.repository()`).

```swift
let repo = spectro.repository()

// Insert a single record
let user = try await repo.insert(User(name: "Alice", email: "alice@example.com"))

// Insert with explicit primary key (e.g. for seeding)
let admin = try await repo.insert(
    User(id: knownUUID, name: "Admin", email: "admin@example.com"),
    includePrimaryKey: true
)

// Get by primary key
let found = try await repo.get(User.self, id: someUUID)

// Get or throw SpectroError.notFound
let mustExist = try await repo.getOrFail(User.self, id: someUUID)

// Fetch all
let everyone = try await repo.all(User.self)

// Update by ID
let updated = try await repo.update(User.self, id: someUUID, changes: [
    "name": "Bob",
    "email": "bob@example.com"
])

// Delete by ID
try await repo.delete(User.self, id: someUUID)
```

### Upsert

Insert or update on conflict using `ConflictTarget`:

```swift
// Upsert on column conflict -- updates all non-PK columns
let user = try await repo.upsert(
    User(name: "Alice", email: "alice@example.com"),
    conflictTarget: .columns(["email"])
)

// Upsert with specific columns to update
let user = try await repo.upsert(
    User(name: "Alice", email: "alice@example.com"),
    conflictTarget: .columns(["email"]),
    set: ["name"]    // only update name on conflict
)

// Upsert on named constraint
let user = try await repo.upsert(
    User(name: "Alice", email: "alice@example.com"),
    conflictTarget: .constraint("users_email_unique")
)
```

### Bulk insert

Insert multiple records in a single query. Automatically batches at 1000 rows to stay under PostgreSQL's parameter limit:

```swift
let users = [
    User(name: "Alice", email: "alice@example.com"),
    User(name: "Bob", email: "bob@example.com"),
    User(name: "Carol", email: "carol@example.com"),
]
let inserted = try await repo.insertAll(users)
```

Skip or update the records that conflict with existing rows, like Ecto's `on_conflict`. The records returned are those inserted or updated:

```swift
let added = try await repo.insertAll(tags, onConflict: .nothing())     // ON CONFLICT DO NOTHING
let synced = try await repo.insertAll(products, onConflict: .replace(on: .columns(["sku"]), columns: ["price"]))
let user = try await repo.insert(newUser, onConflict: .nothing(on: .columns(["email"])))   // nil when skipped
```

### Reloads and batches

```swift
let fresh = try await repo.reload(user)        // nil once deleted
let current = try await repo.reload(users)     // one query, same order

for try await batch in repo.query(User.self).batches(of: 1000) {
    try await export(batch)
}
```

`batches(of:)` reads rows in primary key order, one query per batch, like Ecto's `Repo.stream`, so a large table never sits in memory at once. Iterate in a `repeatableRead` transaction to read one snapshot.

## Changesets

Use `Changeset<YourSchema>.cast` for external parameters before inserting or updating:

```swift
let changeset = Changeset<User>.cast(nil,
    params: ["name": "Alice", "email": "alice@example.com"],
    permitted: ["name", "email"])
    .validateRequired(["name", "email"])
let user = try await repo.insert(changeset)
```

Only permitted schema fields are kept, using Swift property names even when a column has a custom database name. Casting checks the schema type: numeric strings, `"true"`/`"false"` and `"1"`/`"0"` booleans, UUID strings, and ISO 8601 date strings are converted. Invalid values add an `"is invalid"` error and are excluded from `changes`; for example, `"banana"` for an integer field makes `isValid` false before any SQL runs. Non-finite floating-point values are rejected. Explicit optional `nil` values are accepted only for nullable fields.

Pass an existing record instead of `nil` for an update. Direct `Changeset` initialization and `putChange` accept trusted application values without casting.

### Database constraint errors

Declare the database constraints you want to report as field errors. PostgreSQL enforces the constraint during the write, including under concurrent writes:

```swift
let changeset = Changeset<User>.cast(nil,
    params: ["name": "Alice", "email": "alice@example.com"],
    permitted: ["name", "email"])
    .uniqueConstraint("email", name: "users_email_key", message: "is already registered")

do {
    let user = try await repo.insert(changeset)
} catch let error as SpectroError {
    guard let fields = error.fieldErrors else { throw error }
    let response = try JSONEncoder().encode(fields)
    // {"errors":{"email":["is already registered"]}}
}
```

`uniqueConstraint`, `foreignKeyConstraint`, and `checkConstraint` require the exact database constraint or index name and a Swift property name, including when its column is renamed. They match the corresponding PostgreSQL SQLSTATE and the reported table, which defaults to the model's table. A matching insert or update throws `SpectroError.changesetFailed`; unmatched failures, including errors without a reported table, retain their original error. This prevents a trigger's failure on a different table with the same constraint name from becoming a field error on this model. `fieldErrors` and `serverError` also unwrap transaction failures. For local validation errors, keep using the changeset's `errors` or `errorPayload`.

If PostgreSQL reports a partition's physical table instead of the parent table, explicitly declare that origin: `.checkConstraint("amount", name: "amount_positive", onTable: "orders_2026")`. Declare each accepted partition separately, using its exact reported constraint name too. `onTable:` opts into mapping errors from that table, so use it only for origins that belong to the field being validated.

A mapped database failure still aborts its PostgreSQL transaction. Use `TransactionRepo.savepoint` around a write if you intend to catch that failure and continue the transaction.

For a composite constraint, declare the same name on each field that should receive an error. Constraints deferred until transaction commit are reported through `serverError`, because the individual insert or update has already returned.

## Query Builder

`Query<T>` is an immutable value type. Every method returns a new query, so you can safely branch and reuse intermediate queries.

```swift
let repo = spectro.repository()

let base = repo.query(User.self)
    .where { $0.isActive == true }

// Branch 1: recent users
let recent = try await base
    .orderBy({ $0.createdAt }, .desc)
    .limit(10)
    .all()

// Branch 2: count
let total = try await base.count()
```

### Where clauses

```swift
// Equality
.where { $0.name == "John" }
.where { $0.status != "banned" }

// Comparison
.where { $0.age >= 18 }
.where { $0.score < 100 }

// String patterns (case-sensitive)
.where { $0.name.like("J%") }
.where { $0.name.contains("ohn") }          // LIKE '%ohn%'
.where { $0.email.endsWith("@gmail.com") }  // LIKE '%@gmail.com'
.where { $0.name.startsWith("J") }          // LIKE 'J%'

// String patterns (case-insensitive)
.where { $0.name.ilike("%john%") }
.where { $0.name.iContains("john") }        // ILIKE '%john%'
.where { $0.name.iStartsWith("j") }         // ILIKE 'j%'
.where { $0.name.iEndsWith("son") }         // ILIKE '%son'

// Collection
.where { $0.status.in(["active", "pending"]) }
.where { $0.role.notIn(["banned", "suspended"]) }
.where { $0.age.between(18, and: 65) }

// Arrays
.where { $0.tags.contains("swift") }                  // 'swift' = ANY(tags)
.where { $0.tags.containsAll(["swift", "orm"]) }      // tags @> ARRAY[...]
.where { $0.tags.overlaps(["swift", "elixir"]) }      // tags && ARRAY[...]

// Null checks
.where { $0.deletedAt.isNull() }
.where { $0.email.isNotNull() }

// Date
.where { $0.createdAt.isToday() }
.where { $0.createdAt.isThisWeek() }
.where { $0.createdAt.isThisMonth() }
.where { $0.createdAt.isThisYear() }
.where { $0.createdAt.before(cutoffDate) }
.where { $0.createdAt.after(startDate) }

// Logical operators
.where { $0.role == "admin" || $0.role == "moderator" }
.where { ($0.age >= 18) && ($0.isActive == true) }
.where { !($0.status == "banned") }
```

### SQL fragments

For SQL the builder does not cover, write a fragment, like Ecto's `fragment`. Interpolated fields become qualified columns and interpolated values become bound parameters, so values never become SQL text:

```swift
.where { .fragment("lower(\($0.email)) = lower(\(email))") }
.where { .fragment("\($0.settings) ->> 'theme' = \(theme)") }
.where { .fragment("\($0.settings) ? 'beta'") }       // a literal ? is the jsonb operator
.having { _ in .fragment("count(*) > \(10)") }
.orderBy(sql: { "\($0.score) * \(weight)" }, .desc)    // mixes with field sorts in call order
```

Fragments combine with `&&`, `||`, and `!`, and nest: interpolate one `SQLFragment` in another. `\(identifier: name)` inserts a double-quoted identifier. `count()` and aggregates drop the ordering along with its parameters.

Run a whole statement written as a fragment with `executeRawQuery(_:)`, like Ecto's `Repo.query`:

```swift
let rows = try await repo.executeRawQuery(
    "SELECT \(identifier: "id") FROM \(identifier: "posts") WHERE \(identifier: "views") > \(100)"
)
```

### Bulk updates and deletes

`updateAll` and `deleteAll` change every row a query matches in one statement, like Ecto's `update_all` and `delete_all`, and return the number of rows changed:

```swift
let count = try await repo.query(Post.self)
    .where { $0.authorId == authorID }
    .updateAll { [
        $0.views.increment(by: 1),
        $0.tags.push("featured"),                    // array_append; pull(_:) removes
        $0.title.set(sql: "upper(\($0.title))"),
        $0.archivedAt.set(nil),
    ] }

try await repo.query(Session.self).where { $0.expiresAt.before(Date()) }.deleteAll()
```

Without a `where`, they change every row, as in Ecto. Joins, ordering, limits, and offsets choose the rows to change. Soft-deleted rows are left alone unless the query uses `withDeleted()`, and `deleteAll()` sets the deletion time of `@SoftDelete` schemas instead of deleting rows.

### Row locks

Inside a transaction, `lock` keeps other transactions from changing the selected rows until it ends:

```swift
let job = try await spectro.transaction { tx in
    try await tx.query(Job.self)
        .where { $0.state == "queued" }
        .orderBy { $0.insertedAt }
        .limit(1)
        .lock(.update, .skipLocked)                  // FOR UPDATE OF "jobs" SKIP LOCKED
        .first()
}
```

Strengths are `.update`, `.noKeyUpdate`, `.share`, and `.keyShare`; `.noWait` fails with SQLSTATE `55P03` instead of waiting. Only the queried table's rows are locked.

### Ordering

```swift
// Single field (ascending by default)
.orderBy { $0.createdAt }

// Explicit direction
.orderBy({ $0.createdAt }, .desc)

// Multiple fields
.orderBy({ $0.name }, .asc, then: { $0.createdAt }, .desc)
```

### Pagination

```swift
.limit(20)
.offset(40)
```

### Joins

```swift
// Inner join
let results = try await repo.query(User.self)
    .join(Post.self, on: { $0.left.id == $0.right.userId })
    .where { $0.name == "John" }
    .all()

// Left join
let results = try await repo.query(User.self)
    .leftJoin(Post.self, on: { $0.left.id == $0.right.userId })
    .all()

// Decode both sides; an unmatched post is nil.
let pairs: [(User, Post?)] = try await repo.query(User.self)
    .leftJoinAndExecute(Post.self, on: { $0.left.id == $0.right.userId })

// To keep every post, reverse the query and use a left join.
let postsWithUsers: [(Post, User?)] = try await repo.query(Post.self)
    .leftJoinAndExecute(User.self, on: { $0.left.userId == $0.right.id })

// Through join (many-to-many via junction table)
let results = try await repo.query(User.self)
    .joinThrough(Tag.self, through: UserTag.self, on: { builder in
        (builder.main.id == builder.junction.userId,
         builder.junction.tagId == builder.target.id)
    })
    .all()
```

Typed joins use separate column aliases for each model, including custom column names. Nullable fields remain nil; a malformed present row throws a decoding error. Left joins require a nonnullable primary key on the optional side. Model-returning right joins throw because their main model could be absent, which `[T]` and `[(T, U?)]` cannot represent.

Fields in `Query<T>` filters, ordering, selections, grouping, and aggregates refer to `T`'s table, even when a joined table has the same column names. Filter on a joined table with `$0.table(Post.self).title == "Hello"`, or `$0.table(User.self, as: "manager")` for an alias. After `executeJoin`, use `.main` and `.joined` to address either model explicitly.

For a `User` schema with `@Column var managerId: UUID?`, a self join can return each user and their optional manager:

```swift
let pairs = try await repo.query(User.self)
    .leftJoin(User.self, as: "manager", on: { $0.left.managerId == $0.right.id })
    .executeJoin(with: User.self, as: "manager")
    .orderBy { $0.main.name }
    .all()
```

Give every repeated table a distinct alias. When joining another occurrence, `builder.table(User.self, as: "manager")` refers to the earlier occurrence; `builder.right` refers to the one being added. `executeJoin(with:as:)` selects which occurrence to decode alongside the main model. `joinAndExecute` and `leftJoinAndExecute` also accept `as:`. Aliases use 1–63 ASCII letters, digits, or underscores and start with a letter or underscore. Default soft-delete filtering applies to each occurrence; `withDeleted()` includes deleted rows throughout the query.

### Distinct, subqueries, and set operations

```swift
// Remove the duplicates a join adds, or keep each author's most viewed post.
.join(Comment.self) { $0.left.id == $0.right.postId }.distinct()
.distinct { $0.authorId }.orderBy({ $0.views }, .desc)       // DISTINCT ON

// Compare columns, filter with subqueries, and test existence.
.where { $0.likes > $0.views }
.where { $0.id.in(repo.query(Post.self).where { $0.views > 100 }.select { $0.authorId }) }
.where { post in .exists(repo.query(Comment.self).where { $0.postId == post.id }) }
.where { post in !.exists(repo.query(Comment.self).where { $0.postId == post.id }) }
let hasAdmins = try await repo.query(User.self).where { $0.isAdmin == true }.exists()

// Combine queries; clauses added afterwards apply to the combined rows.
let feed = try await mine.union(pinned).orderBy({ $0.createdAt }, .desc).limit(20).all()
```

`distinct { }` sorts by its columns first, as PostgreSQL's `DISTINCT ON` requires and as Ecto does, and counts and aggregates see each remaining row once. `union`, `unionAll`, `intersect`, `intersectAll`, `except`, and `exceptAll` keep each query's own filters, ordering, and limit. A correlated subquery refers to the outer query's fields, as `post.id` does above; a subquery of the same table cannot, because its own columns have the same names. As in SQL, `notIn` matches no row when the subquery selects a NULL.

### Recursive queries

`recursive` follows rows from the query's rows, like a `WITH RECURSIVE` CTE. In its closure, `$0.left` is a row of the table and `$0.right` a row already found:

```swift
let subtree = try await repo.query(Category.self)
    .where { $0.id == rootID }
    .recursive { $0.left.parentId == $0.right.id }   // ancestors: $0.left.id == $0.right.parentId
    .orderBy { $0.name }
    .all()
```

A row found again is not followed again, so cycles end. Soft-deleted rows are not reached unless the query uses `withDeleted()`.

### Query inspection

```swift
let query = repo.query(User.self).where { $0.email == "alice@example.com" }
let statement = try query.statement() // No database call
print(statement.sql)                // SQL with numbered placeholders
// statement.parameters contains the separate bound values.

let plan = try await query.explain() // Plain EXPLAIN, without ANALYZE
let measured = try await query.timedAll()
let users = measured.rows
let elapsed = measured.duration     // Duration, including row decoding
```

These methods also work on `TupleQuery` and typed `JoinQuery`. `statement()` describes the SELECT used by `all()`, not a count or aggregate. `timedAll()` executes once and propagates errors unchanged. All three retain the query's transaction executor. Nothing is logged automatically.

### Terminal methods

| Method | Returns | Description |
|--------|---------|-------------|
| `.all()` | `[T]` | Execute query, return all matching rows |
| `.first()` | `T?` | Execute query, return first row or nil |
| `.firstOrFail()` | `T` | Execute query, throw `SpectroError.notFound` if empty |
| `.count()` | `Int` | Return count of matching rows |
| `.exists()` | `Bool` | Whether any row matches |
| `.batches(of:)` | `QueryBatches<T>` | Iterate matching rows in primary key batches |

## Relationships

### Defining relationships

```swift
@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @HasMany var posts: [Post]
    @HasOne var profile: Profile?
    @ManyToMany(junctionTable: "user_tags", parentFK: "userId", relatedFK: "tagId")
    var tags: [Tag]
}

@Schema("posts")
struct Post {
    @ID var id: UUID
    @Column var title: String
    @ForeignKey var userId: UUID
    @BelongsTo var user: User?
}

@Schema("profiles")
struct Profile {
    @ID var id: UUID
    @Column var bio: String
    @ForeignKey var userId: UUID
}

@Schema("tags")
struct Tag {
    @ID var id: UUID
    @Column var name: String
}

@Schema("user_tags")
struct UserTag {
    @ID var id: UUID
    @ForeignKey var userId: UUID
    @ForeignKey var tagId: UUID
}
```

### Preloading (N+1 prevention)

Preloading executes one additional query per relationship (not one per row):

```swift
// Load users with their posts (2 queries total)
let users = try await repo.query(User.self)
    .preload(\.$posts)
    .all()

// Chain multiple preloads
let users = try await repo.query(User.self)
    .preload(\.$posts)
    .preload(\.$profile)
    .preload(\.$tags)        // many-to-many preload
    .all()

// Override foreign key when it doesn't follow convention
let posts = try await repo.query(Post.self)
    .preload(\.$author, foreignKey: "authorId")
    .all()
```

Customize the query that loads a relationship, and preload the related records' own relationships. Each level is still one query:

```swift
let users = try await repo.query(User.self)
    .preload(\.$posts) { posts in
        posts.where { $0.published == true }
            .orderBy({ $0.createdAt }, .desc)
            .preload(\.$comments)
    }
    .all()
```

A limit in a customization applies to all parents together. For records already fetched, `repo.preload` loads a relationship in one query, also inside transactions:

```swift
let users = try await repo.query(User.self).all()
let withPosts = try await repo.preload(users, \.$posts)
let user = try await repo.preload(users[0], \.$profile)
```

Preload queries support chaining with `.where()`, `.orderBy()`, and `.limit()`:

```swift
let users = try await repo.query(User.self)
    .where { $0.isActive == true }
    .preload(\.$posts)
    .orderBy({ $0.name }, .asc)
    .limit(50)
    .all()
```

## Transactions

Transactions use `READ COMMITTED` isolation by default, with automatic rollback on error. The closure receives a `Repo`-conforming object with full CRUD and query builder support:

```swift
let (user, profile) = try await spectro.transaction { repo in
    let user = try await repo.insert(User(name: "Alice", email: "alice@example.com"))
    let profile = try await repo.insert(Profile(bio: "Hello!", userId: user.id))

    // Query builder works inside transactions
    let count = try await repo.query(User.self)
        .where { $0.isActive == true }
        .count()

    return (user, profile)
}
```

Both `GenericDatabaseRepo` and `TransactionRepo` conform to the `Repo` protocol, so code that accepts `any Repo` works transparently inside and outside transactions. The `QueryExecutor` protocol allows `Query<T>` to execute against both pooled connections and pinned transaction connections.

Nested transactions are not supported and will throw `SpectroError.transactionAlreadyStarted`. To recover from a failed step without aborting the whole transaction, run it in a savepoint:

```swift
try await spectro.transaction { repo in
    guard let tx = repo as? TransactionRepo else { return }
    let order = try await tx.insert(Order(total: 42))
    do {
        try await tx.savepoint { sp in
            _ = try await sp.insert(Coupon(code: code, orderId: order.id))
        }
    } catch let error as SpectroError where error.serverError?.sqlState == "23505" {
        // The coupon insert was rolled back; the transaction is still usable.
    }
}
```

Ask for a stricter isolation level when a transaction must not see concurrent changes. PostgreSQL may then abort it with SQLSTATE `40001`; run it again:

```swift
let balance = try await spectro.transaction(isolation: .serializable) { tx in
    // read, check, and write as if no other transaction ran meanwhile
}
```

`savepoint` releases the savepoint when its body returns, and rolls back to it when the body throws, rethrowing the body's error unchanged. Savepoints can nest.

Errors a transaction's body throws come back wrapped in `SpectroError.transactionFailed`, and database errors in `queryExecutionFailed`. `SpectroError.serverError` unwraps them and returns the PostgreSQL error's SQLSTATE, message, constraint, table, column, and detail, or `nil` when the server reported none.

## Aggregates and GROUP BY

### Simple aggregates

```swift
let total = try await repo.query(Order.self)
    .where { $0.status == "completed" }
    .sum { $0.amount }         // Double?

let average = try await repo.query(Order.self)
    .avg { $0.amount }         // Double?

let highest = try await repo.query(Order.self)
    .max { $0.amount }         // Double?

let lowest = try await repo.query(Order.self)
    .min { $0.amount }         // Double?

let count = try await repo.query(Order.self)
    .where { $0.status == "completed" }
    .count()                   // Int
```

### Grouped aggregates

Combine `.groupBy()` with grouped aggregate methods to get per-group results:

```swift
// Sum of order amounts grouped by status
let results = try await repo.query(Order.self)
    .groupBy { $0.status }
    .groupedSum { $0.amount }
// returns [GroupedResult] where each has .group["status"] and .value

// Group by multiple fields
let results = try await repo.query(Order.self)
    .groupBy({ $0.status }, { $0.region })
    .groupedCount()

// HAVING clause
let results = try await repo.query(Order.self)
    .groupBy { $0.status }
    .having { $0.amount > 100 }
    .groupedSum { $0.amount }
```

Available grouped methods: `groupedSum`, `groupedAvg`, `groupedMin`, `groupedMax`, `groupedCount`.

Each returns `[GroupedResult]`:

```swift
public struct GroupedResult: Sendable {
    public let group: [String: String]   // GROUP BY column values
    public let value: Double?            // aggregate result
}
```

## JSON Encoding

Every `@Schema` type automatically conforms to `Encodable`, so you can pass schema instances directly to `JSONEncoder` or any API that accepts `Encodable`:

```swift
let user = try await repo.get(User.self, id: someUUID)
let json = try JSONEncoder().encode(user)
```

### Key strategy

JSON keys use `snake_case` by default, matching the database column convention:

```swift
@Schema("products")
struct Product {
    @ID var id: UUID                    // → "id"
    @Column var productName: String     // → "product_name"
    @Column var isAvailable: Bool       // → "is_available"
    @Timestamp var createdAt: Date      // → "created_at"
}
```

`@Column("custom_name")` overrides take precedence over the automatic conversion:

```swift
@Column("display") var displayName: String  // → "display" (not "display_name")
```

### Relationship encoding

Relationship fields are only included in the JSON when they have been loaded. If a relationship is `.notLoaded`, its key is omitted entirely -- no nulls or empty arrays leak into responses:

```swift
// User fetched without preloading -- relationships omitted from JSON
let user = try await repo.get(User.self, id: someUUID)
// → {"id": "...", "name": "Alice", "email": "alice@example.com", "created_at": "..."}

// User fetched with preloading -- relationships included
let user = try await repo.query(User.self)
    .preload(\.$posts)
    .firstOrFail()
// → {"id": "...", "name": "Alice", ..., "posts": [{...}, {...}]}
```

### Opting out

If you don't want `Encodable` generated (e.g., for internal-only schemas), pass `encodable: false`:

```swift
@Schema("secrets", encodable: false)
struct Secret {
    @ID var id: UUID
    @Column var value: String
}
```

## Field Selection

Select specific columns instead of `SELECT *` using `TupleQuery`:

```swift
// Single field
let names: [String] = try await repo.query(User.self)
    .select { $0.name }
    .all()

// Two fields
let pairs: [Tuple2<String, String>] = try await repo.query(User.self)
    .select { ($0.name, $0.email) }
    .all()
// Access: pairs[0]._0 (name), pairs[0]._1 (email)

// Three fields
let triples: [Tuple3<String, String, Int>] = try await repo.query(User.self)
    .select { ($0.name, $0.email, $0.age) }
    .all()

// Four fields
let quads: [Tuple4<UUID, String, String, Bool>] = try await repo.query(User.self)
    .select { ($0.id, $0.name, $0.email, $0.isActive) }
    .all()
```

Select SQL expressions too, such as aggregates of a grouped query or window functions. Each expression decodes as the type you give, an `Optional` when it can be NULL:

```swift
let totals: [Tuple2<UUID, Int>] = try await repo.query(Post.self)
    .groupBy { $0.authorId }
    .having { .fragment("count(*) > \(1)") }
    .select { ($0.authorId, $0.expression("sum(\($0.views))", as: Int.self)) }
    .orderBy(sql: { "sum(\($0.views))" }, .desc)
    .all()

let ranked = try await repo.query(Post.self)
    .select { ($0.title, $0.expression("rank() OVER (PARTITION BY \($0.authorId) ORDER BY \($0.views) DESC)", as: Int.self)) }
    .all()
```

`TupleQuery` supports `.where()`, `.orderBy()`, `.limit()`, `.offset()`, `.distinct()`, `.first()`, `.firstOrFail()`, and `.count()`. A projection of a query with `groupBy` returns one result per group, and `count()` counts the groups.

## CLI Reference

| Command | Purpose |
|---|---|
| `spectro database create <name>` | Create a PostgreSQL database |
| `spectro database drop <name>` | Confirm and drop a database; `--force` skips confirmation |
| `spectro migrate init --target MyAppMigrations` | Scaffold a Swift migration target and print its manifest declaration |
| `spectro generate migration CreateUsers` | Generate Swift when configured, otherwise SQL |
| `spectro migrate plan [--migration <id>] [--direction up\|down]` | Preview registered migrations without connecting to PostgreSQL |
| `spectro migrate up` | Apply all pending migrations |
| `spectro migrate down --step 1` | Roll back the newest completed migration; **omit `--step` to roll back all** |
| `spectro migrate status` | Read migration status without creating the tracking table |
| `spectro help migrate <command>` | Show command help without building the project |

Legacy database and SQL migration commands accept `--username`, `--password`, and `--database`. Values resolve in order: CLI flags > `.env` file > environment variables > defaults.

With `.spectro.json` configured, `up`, `down`, `status`, and `plan` launch the project's compiled migration executable through SwiftPM. Its database commands use flags and process environment; they do not automatically read `.env`. Initialization, Swift generation, help, and planning need no database; SwiftPM may still resolve dependencies and build the executable. See the [complete CLI reference](docs/CLI.md) for options, workflow selection, credentials, and exit status.

### Swift migration declarations

Add the optional `SpectroMigrations` product to a dedicated executable target. Declare changes and register each migration explicitly:

```swift
import SpectroMigrations

struct CreateUsers: Migration {
    static let id = "1791129600_create_users"

    var change: MigrationPlan {
        CreateTable("users") { table in
            table.column("id", .uuid).primaryKey().default(.sql("gen_random_uuid()"))
            table.column("email", .text).notNull()
            table.timestamps()
        }
        CreateIndex("users_email_index", on: "users", columns: ["email"]).unique()
    }
}
```

The compiler derives rollback in reverse order: drop the index, then the table. `Reversible`, paired `SQL(up:down:)`, and `Irreversible` cover changes that need an explicit policy. Existing SQL files can be bundled unchanged alongside new Swift declarations, using the same migration history.

The [migration guide](docs/MIGRATIONS.md) walks through target setup, registration, SQL adoption, and deployment. During development, `spectro` launches the project executable; production runs the built executable with its resources and runtime libraries, without SwiftPM, Mint, or a compiler.

### Migration files

Without a Swift project descriptor, migrations remain plain SQL in `Sources/Migrations/`, named `<unix_timestamp>_<name>.sql`:

```sql
-- migrate:up
CREATE TABLE "users" (
    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "name" TEXT NOT NULL DEFAULT '',
    "email" TEXT NOT NULL DEFAULT '',
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- migrate:down
DROP TABLE "users";
```

The SQL statement parser handles semicolons inside dollar-quoted and escape strings, quoted identifiers, inline `--` comments, and nested `/* */` comments.

Each migration runs on one PostgreSQL connection in a transaction that includes its tracking update. A failed `up` rolls back its schema changes and remains pending; a failed `down` preserves the applied schema and completed status. Correct the failed SQL and retry. Earlier migrations in the same run remain committed. Migration files must not contain transaction-control statements (`BEGIN`, `COMMIT`, `ROLLBACK`) or commands that cannot run inside a transaction, such as `CREATE INDEX CONCURRENTLY`.

Migration commands acquire a database-wide PostgreSQL advisory lock before creating tracking objects or reading pending/applied migrations. The lock spans the entire command, while each migration has its own transaction. Competing runners re-read the tracking table after acquiring ownership. This requires a direct database connection or a proxy with session pooling; transaction pooling cannot preserve this session lock.

The default lock wait is 30 seconds and can be configured with `spectro.migrationManager(lockTimeout: .seconds(10))`. This limits waiting for another migration runner, separately from pool acquisition and SQL execution. Cancellation is supported while waiting for a pool connection, waiting for the lock, or executing SQL. Each command closes its reserved session before returning the pool slot, releasing locks and rolling back any unfinished transaction. PostgreSQL 14+ sessions enable `client_connection_check_interval` at 100ms to detect client termination during long-running SQL on supported hosts ([PostgreSQL documentation](https://www.postgresql.org/docs/16/runtime-config-connection.html#GUC-CLIENT-CONNECTION-CHECK-INTERVAL)). Disconnect recovery during a network outage still depends on the server's TCP failure detection.

### Application acceptance

The [IssueTracker example](Examples/IssueTracker/README.md) uses Peregrine and Spectro's public APIs against a real PostgreSQL database. On a compatible macOS build host with Swift 6.3+ and an Xcode 26.3+ SDK selected (macOS 15.6+ for Xcode 26.3), run `python3 scripts/acceptance.py` to build the example and verify HTTP joins, changesets, transaction rollback, competing writes, populated-database upgrades, and restart persistence. These toolchain requirements come from Peregrine's dependencies; the example package's deployment target is macOS 14. The command creates and removes its own database. Spectro's core test suite still runs on Linux/Swift 6.1; the pinned Peregrine release currently blocks Linux HTTP builds with an Apple-only logging import.

### Generate a SQL migration

In a project without `.spectro.json`, generation needs database access to record the pending migration:

```bash
spectro generate migration CreateUsers
# Creates: Sources/Migrations/<unix_timestamp>_create_users.sql
```

### Run migrations

```bash
# Apply all pending
spectro migrate up

# Rollback last migration
spectro migrate down --step 1

# Rollback N migrations
spectro migrate down --step 3

# Check status
spectro migrate status
```

## Architecture

Spectro is organized into five production targets:

| Target | Product | Role |
|---|---|---|
| `SpectroCommon` | `SpectroCommon` | Shared types (zero external deps): `Inflector`, `MigrationFile`, `MigrationRecord`, error enums, `String.snakeCase()` |
| `SpectroMacros` | Compiler plugin | `@Schema` macro implementation via SwiftSyntax |
| `Spectro` | `SpectroKit` | Core ORM library: schemas, query builder, connection pool, migrations |
| `SpectroMigrations` | `SpectroMigrations` | Optional Swift migration DSL, compiler, registry, executable command |
| `SpectroCLI` | `spectro` | CLI executable (ArgumentParser-based) |

### Core actors

- **`DatabaseConnection`** -- wraps an NIO `EventLoopGroupConnectionPool<PostgresConnectionSource>`; bridges futures to async/await via `withCheckedThrowingContinuation`; tracks in-flight operations for safe shutdown
- **`GenericDatabaseRepo`** -- implements the `Repo` protocol; primary CRUD layer with query building, raw SQL, and transaction support
- **`SchemaRegistry`** -- singleton actor; inspects schema types via `Mirror`; caches field metadata for row mapping

### Key protocols

- **`Schema`** -- requires `tableName: String` and `init()`
- **`SchemaBuilder`** -- adds `static func build(from: [String: Any]) -> Self` for reflection-free row mapping
- **`PrimaryKeyType`** -- `UUID`, `Int`, `String` conformances; provides `toPostgresData()`, `fromPostgresData()`, `defaultValue`, `fieldType`
- **`Repo`** -- common interface for `GenericDatabaseRepo` and `TransactionRepo`; defines `get`, `insert`, `update`, `delete`, `upsert`, `insertAll`, `transaction`, `query`
- **`QueryExecutor`** -- abstraction over query execution so `Query<T>` works with both pooled connections and pinned transaction connections

### Query builder internals

`Query<T>` stores conditions with `?` as positional sentinels. Placeholder numbering (`$1`, `$2`, ...) is applied in a single left-to-right pass at SQL assembly time via `renumberPlaceholders()`. This means individual operators never need to know their absolute parameter index.

### Data flow

```
Spectro (facade)
  └─ GenericDatabaseRepo (actor, Repo protocol)
       └─ DatabaseConnection (actor, QueryExecutor protocol)
            └─ EventLoopGroupConnectionPool<PostgresConnectionSource>
                 └─ PostgresConnection (NIO EventLoop)

Query<T> ──execute──▶ QueryExecutor.executeQuery()
                        ├─ DatabaseConnection (pooled)
                        └─ TransactionContext (pinned connection)
```

## Configuration

### Environment variables

```
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=postgres
DB_NAME=myapp_dev
```

### .env file

Legacy SQL migration and database commands read `.env` from the current directory. Run them from your project root to use a file there:

```
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=postgres
DB_NAME=myapp_dev
```

Compiled Swift migration executables do not automatically load `.env`. Export these values in the process environment, or supply an explicit configuration provider. See the [CLI configuration reference](docs/CLI.md#database-configuration) for defaults and precedence in each workflow.

### Programmatic configuration

```swift
// From explicit parameters
let spectro = try Spectro(
    hostname: "localhost",
    port: 5432,
    username: "postgres",
    password: "postgres",
    database: "myapp_dev",
    maxConnectionsPerEventLoop: 4
)

// From environment variables (DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)
let spectro = try Spectro.fromEnvironment()

// From a DatabaseConfiguration struct (supports TLS)
let config = DatabaseConfiguration(
    hostname: "db.example.com",
    port: 5432,
    username: "app",
    password: "secret",
    database: "production",
    maxConnectionsPerEventLoop: 8,
    numberOfThreads: System.coreCount,
    tlsConfiguration: TLSConfiguration.makeClientConfiguration() // import NIOSSL
)
let spectro = try Spectro(configuration: config)
```

Pass `logger` to log each statement at debug level with its SQL, row count, and timings, never its bound values. Pass `onQuery` to receive a `QueryEvent` per statement, with its SQL, parameters, query time, queue time, row count, and error, for metrics or tracing:

```swift
var logger = Logger(label: "app.db")  // import Logging
logger.logLevel = .debug
let config = DatabaseConfiguration(
    username: "app", password: "secret", database: "production",
    logger: logger,
    onQuery: { event in metrics.record(event.sql, event.queryTime) }
)
```

The observer runs on a connection's event loop, so keep it fast.

A supplied `tlsConfiguration` requires TLS and retains its certificate verification settings; it never falls back to an unencrypted connection. The default `nil` disables TLS for local connections. Invalid TLS configuration fails initialization.

## Development

### Prerequisites

- Swift 6.1+ (install via [mise](https://mise.jdx.dev/), `brew install swift`, or [swiftly](https://swift-server.github.io/swiftly/))
- PostgreSQL (local install or Docker)

### Build

```bash
# Debug build
swift build

# Release build
swift build -c release

# CLI only
swift build --product spectro

# Run CLI from source
"$(swift build --show-bin-path)/spectro" --help
```

### Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [postgres-kit](https://github.com/vapor/postgres-kit) | 2.7+ | PostgreSQL driver and connection pooling |
| [sql-kit](https://github.com/vapor/sql-kit) | 3.30+ | SQL building utilities |
| [async-kit](https://github.com/vapor/async-kit) | 1.15+ | Connection pool infrastructure |
| [swift-nio](https://github.com/apple/swift-nio) | 2.34+ | Async I/O runtime |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.2+ | CLI argument parsing |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | 600+ | `@Schema` macro implementation |

## Testing

Tests use [Swift Testing](https://developer.apple.com/documentation/testing/) (`@Suite`, `@Test`), not XCTest.

### Setup

Integration tests require a live PostgreSQL database:

```bash
# Set environment variables (or use defaults)
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=postgres
export DB_PASSWORD=postgres
export TEST_DB_NAME=spectro_test

# Create the test database (one-time)
./Tests/setup_test_db.sh
```

### Run tests

```bash
# All tests
swift build --product spectro
swift test

# Specific suite
swift test --filter CoreFunctionalTests

# Query tests only
swift test --filter QueryTests

# Aggregate tests
swift test --filter AggregateQueryTests

# Migration DSL and executable command tests (no database needed)
swift test --filter SpectroMigrationsTests
```

With an external scratch directory, set `SPECTRO_CLI_PATH` to its built `spectro` executable when running CLI tests. The [migration artifact acceptance](docs/MIGRATIONS.md#verify-the-distribution-contract) additionally checks copied binaries, SQL resources, interruption, and compiler-free deployment.

### Sandbox your application's tests

`spectro.sandbox` runs its body in a transaction that is always rolled back, like Ecto's SQL sandbox. Every repository made from that `Spectro` instance, in the body and its child tasks, uses the transaction, so code under test needs no changes and leaves no data behind:

```swift
@Test func registration() async throws {
    try await spectro.sandbox { repo in
        try await RegistrationService(repo: spectro.repository()).register(email: "ana@example.com")
        #expect(try await repo.query(User.self).count() == 1)
    }
}
```

Each statement runs in its own savepoint, so a test can expect a constraint error and keep going. `transaction` inside a sandbox becomes a savepoint, so a failed transaction rolls back alone. A transaction holds the sandbox's connection until it ends, and other tasks' statements wait for it, so concurrent transactions cannot undo each other. `Task { }` inherits the sandbox, and its statements throw once the sandbox has ended rather than reaching the database; `Task.detached` uses the pool as usual.

### Test structure

```
Tests/SpectroTests/
├── Helpers/
│   ├── TestDatabase.swift        # Test DB connection setup
│   └── TestSchemas.swift         # Schema definitions for tests
├── SchemaTests/
│   ├── SchemaTests.swift         # Schema registration and metadata
│   ├── RelationshipTests.swift   # Relationship property wrappers
│   ├── LazyLoaderTests.swift     # SpectroLazyRelation state machine
│   ├── MacroLoaderInjectionTests.swift
│   └── EncodableSchemaTests.swift # Encodable conformance generation
├── QueryTests/
│   ├── QueryTests.swift          # SQL generation for Query<T>
│   ├── QueryOperatorTests.swift  # All operator combinations
│   ├── QueryExecutionTests.swift # Live query execution
│   ├── PreloadTests.swift        # Relationship preloading
│   └── AggregateQueryTests.swift # SUM, AVG, MIN, MAX, GROUP BY
├── RepoTests/
│   ├── RepositoryTests.swift     # CRUD operations
│   ├── NonUUIDPrimaryKeyTests.swift # Int and String PK support
│   ├── UpsertBulkInsertTests.swift  # Upsert and insertAll
│   └── TransactionTests.swift    # Transaction isolation and rollback
├── CLITests/                     # Real SQL commands, scaffolding and launcher supervision
└── MigrationTests/
    ├── MigrationManagerTests.swift
    ├── MigrationRunnerTests.swift
    ├── MigrationDSLIntegrationTests.swift
    ├── MigrationSQLBoundaryTests.swift
    ├── SQLStatementParserTests.swift
    └── StringCase.swift          # snake_case conversion
```

`Tests/SpectroMigrationsTests/` covers the DSL, compiler, registry, command parsing, and documentation examples without a database. `Tests/Fixtures/SwiftMigrationsConsumer/` is a separate consumer package used by the release-artifact acceptance harness.

## Troubleshooting

### Connection refused

```
SpectroError.connectionFailed: Database connection failed
```

1. Verify PostgreSQL is running: `pg_isready` or `docker ps`
2. Check env vars: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`
3. Verify the database exists: `psql -l | grep myapp_dev`

### Insert did not return a row

```
SpectroError.databaseError: Insert did not return a row
```

The table likely does not exist. Run migrations first:

```bash
spectro migrate up
```

### Schema must implement SchemaBuilder

```
SpectroError.invalidSchema: Schema User must implement SchemaBuilder
```

Either use the `@Schema` macro or manually conform to `SchemaBuilder`:

```swift
// Option A: use the macro
@Schema("users")
struct User { ... }

// Option B: manual conformance
struct User: Schema, SchemaBuilder {
    static func build(from values: [String: Any]) -> User { ... }
}
```

### Transaction already started

```
SpectroError.transactionAlreadyStarted
```

Nested transactions are not supported. Keep all work within a single `transaction` closure, and use `TransactionRepo.savepoint` for steps that must roll back on their own.

### Connection lifecycle

Always call `await spectro.shutdown()` before releasing the `Spectro` instance. The connection pool tracks in-flight operations and waits for them to complete before tearing down.

Test crashes are failures. CI uses the exit status of `swift test`, including compilation errors and signals, rather than inferring success from partial output.

## License

MIT

### Exact text comparisons

Use `$0.name.binaryCollated() == value` (also available on nullable text fields)
to compare exact bytes independently of the column or database collation. Ordering
uses PostgreSQL's `C` collation, hence lexicographic UTF-8 order on UTF-8 databases.
This does not normalize Unicode, fold case, change stored data, or alter an index's
collation. An index used for these comparisons must have a matching collation.
