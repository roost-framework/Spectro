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
- **Type-safe aggregates** -- `.sum()`, `.avg()`, `.min()`, `.max()`, `.count()` with `GROUP BY` and `HAVING` support
- **Upsert and bulk insert** -- `ON CONFLICT` upserts and multi-row inserts with automatic batching
- **Relationship preloading** -- batch-loads `HasMany`, `HasOne`, `BelongsTo`, and `ManyToMany` relationships to prevent N+1 queries
- **Transaction support** -- `READ COMMITTED` isolation with automatic rollback; full CRUD and query builder available inside transactions via `QueryExecutor`
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
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.3.1")
```

The `CLI`, `RichTerminal`, and `Migrations` traits, on by default, bring the dependencies of the `spectro` command (ArgumentParser, plus Noora for colors, spinners, prompts, and tables) and `SpectroMigrations`. If you only use SpectroKit, disable them so SwiftPM never fetches ArgumentParser or Noora:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.3.1", traits: [])
```

To build the `spectro` command from your dependencies without Noora, as Roost does for `roost spectro`, enable only `CLI`; the command then prints plain text:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.3.1", traits: ["CLI"])
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
mint install roost-framework/Spectro@2.3.1
```

Pin a version in your `Mintfile`:

```
roost-framework/Spectro@2.3.1
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

Add `@SoftDelete var deletedAt: Date?` and a matching nullable `TIMESTAMPTZ` database column to opt into soft deletes. `@Schema` generates the filtering metadata and timestamp mapping. `repo.delete` records the deletion time; normal reads exclude deleted records, while `repo.query(User.self).withDeleted()` includes them. For manual schemas, implement `softDeleteColumn` with the database column name and decode the timestamp in `build(from:)`.

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

Typed joins use separate column aliases for each model, including custom column names. Nullable fields remain nil; a malformed present row throws a decoding error. Left joins require a nonnullable primary key on the optional side. Self joins and repeated tables require aliases and are not supported by `executeJoin` yet. Model-returning right joins throw because their main model could be absent, which `[T]` and `[(T, U?)]` cannot represent.

### Terminal methods

| Method | Returns | Description |
|--------|---------|-------------|
| `.all()` | `[T]` | Execute query, return all matching rows |
| `.first()` | `T?` | Execute query, return first row or nil |
| `.firstOrFail()` | `T` | Execute query, throw `SpectroError.notFound` if empty |
| `.count()` | `Int` | Return count of matching rows |

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

Transactions use `READ COMMITTED` isolation with automatic rollback on error. The closure receives a `Repo`-conforming object with full CRUD and query builder support:

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

Nested transactions are not supported and will throw `SpectroError.transactionAlreadyStarted`.

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

`TupleQuery` supports `.where()`, `.orderBy()`, `.limit()`, `.offset()`, `.first()`, `.firstOrFail()`, and `.count()`.

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

Nested transactions are not supported. Restructure your code so that all work happens within a single `transaction` closure.

### Connection lifecycle

Always call `await spectro.shutdown()` before releasing the `Spectro` instance. The connection pool tracks in-flight operations and waits for them to complete before tearing down.

Test crashes are failures. CI uses the exit status of `swift test`, including compilation errors and signals, rather than inferring success from partial output.

## License

MIT
