# Queries and relationships

Compose immutable queries and choose between joined reads and relationship preloading.

## Overview

### Build a query

```swift
let query = repo.query(User.self)
    .where { $0.name == "Alice" }
    .orderBy({ $0.createdAt }, .desc)

let users = try await query.limit(20).all()
let count = try await query.count()
let first = try await query.first()
```

``Query`` is a value type. Filtering, ordering, and limiting return a new query; terminal methods execute it. Use `firstOrFail()` when absence should throw, and `page(size:page:)` for a ``Page`` with items, total count, and navigation metadata. Page numbers start at one.

The query builder binds values separately from SQL text. Use the API's typed fields for filters, ordering, grouping, and aggregates.

### Write SQL fragments

```swift
let users = try await repo.query(User.self)
    .where { .fragment("lower(\($0.email)) = lower(\(email))") }
    .where { .fragment("\($0.settings) ? 'beta'") }
    .all()
```

``QueryCondition/fragment(_:)`` takes an ``SQLFragment``, like Ecto's `fragment`. Interpolated fields become qualified columns and interpolated values become bound parameters, while a literal `?`, such as the `jsonb` operator, stays in the SQL. Filter on a joined table with `$0.table(Post.self).title`.

``Query/orderBy(sql:_:)`` sorts by a fragment, in call order with field sorts, and ``Repo/executeRawQuery(_:)`` runs a whole statement written as a fragment.

### Update, delete, and lock many rows

```swift
let updated = try await repo.query(Post.self)
    .where { $0.authorId == authorID }
    .updateAll { [$0.views.increment(by: 1), $0.tags.push("featured")] }
let deleted = try await repo.query(Session.self).where { $0.expiresAt.before(Date()) }.deleteAll()

let job = try await client.transaction { tx in
    try await tx.query(Job.self).limit(1).lock(.update, .skipLocked).first()
}
```

`updateAll(_:)` and `deleteAll()` change every matching row in one statement and return how many changed. Each ``FieldAssignment`` sets a value, a SQL expression, an increment, or an array element. `deleteAll()` sets the deletion time of soft-deleted models. `lock(_:_:)` takes a ``RowLockStrength`` and a ``RowLockWait`` and locks the queried table's rows until the transaction ends.

### Declare a relationship

```swift
@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @Timestamp var createdAt: Date
    @HasMany var posts: [Post]
}

@Schema("posts")
struct Post {
    @ID var id: UUID
    @Column var title: String
    @ForeignKey var userId: UUID
    @BelongsTo var user: User?
}
```

``ForeignKey`` describes the stored key, while ``HasMany``, ``HasOne``, ``BelongsTo``, and ``ManyToMany`` describe loading relationships. Create actual foreign-key constraints and indexes through migrations.

### Preload related records

```swift
let users = try await repo.query(User.self)
    .orderBy({ $0.name }, .asc)
    .preload(\.$posts)
    .all()
```

Use the projected relationship key path, such as `\.$posts`. Preloading batches related records for the selected parents instead of issuing one query per parent. Supply `foreignKey:` when the field does not follow the naming convention. Chain preloads to load multiple relationships.

```swift
let authors = try await repo.query(User.self)
    .preload(\.$posts) { $0.where { $0.published == true }.preload(\.$comments) }
    .all()
let withProfiles = try await repo.preload(authors, \.$profile)
```

A ``PreloadCustomization`` returns a ``ModelQuery`` that loads the related records: filter and order them, or preload their own relationships, with one query per level. `preload(_:_:foreignKey:_:)` on a ``Repo`` loads a relationship of records already fetched.

### Return typed joined models

```swift
let postsWithUsers: [(Post, User?)] = try await repo.query(Post.self)
    .leftJoinAndExecute(User.self, on: { $0.left.userId == $0.right.id })
```

Each side has its own column projection. A missing right-side row is `nil`; a present row that cannot decode throws. Typed left joins require a nonnullable primary key on the optional side to distinguish absence.

Model-returning right joins cannot represent an absent main model and throw. Reverse the query and use a left join when you need to retain all rows from the other table.

### Alias repeated tables

For a `User` with `@Column var managerId: UUID?`, use a distinct alias for its manager:

```swift
let pairs = try await repo.query(User.self)
    .leftJoin(User.self, as: "manager", on: { $0.left.managerId == $0.right.id })
    .executeJoin(with: User.self, as: "manager")
    .orderBy { $0.main.name }
    .all()
```

Select the joined occurrence with `executeJoin(with:as:)`. When building a later join, `builder.table(User.self, as: "manager")` references an earlier alias. Each occurrence retains its own custom column mapping and soft-delete filter. Aliases must be distinct, contain 1–63 ASCII letters, digits, or underscores, and start with a letter or underscore.

### Inspect and measure a query

```swift
let query = repo.query(User.self).where { $0.name == "Alice" }
let statement = try query.statement()
let sql = statement.sql
let parameters = statement.parameters
let plan = try await query.explain()
let measured = try await query.timedAll()
```

``QueryStatement`` keeps SQL and bind values separate. `statement()` renders the SELECT used by `all()` without executing it. `explain()` uses plain PostgreSQL EXPLAIN without ANALYZE. ``TimedQueryResult`` contains `rows` and a `Duration` measured over one execution including decoding. These methods also support projections and typed joins, use the original executor, and never log automatically.

Query operations also work on the repository supplied to a transaction. See <doc:TransactionsAndConfiguration>.
