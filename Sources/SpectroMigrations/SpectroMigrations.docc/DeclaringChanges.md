# Declaring schema changes

Describe historical tables, columns, indexes, and constraints as immutable Swift values.

## Overview

### Keep history stable

A ``Migration`` has a full ID such as `1791129600_create_users` and a ``MigrationPlan`` built by its `change` property. The generator assigns an epoch-seconds prefix and lower snake case name once. Never change an applied ID, and keep every applied declaration in later artifacts.

Use historical names and types directly. A migration must not derive its shape from today's application model, clock, network, or environment. The registry evaluates each declaration once and captures its plan. Swift conditionals and loops are available through the result builders; their inputs must remain deterministic.

### Create a table

```swift
struct CreateIssues: Migration {
    static let id = "1791129601_create_issues"

    var change: MigrationPlan {
        CreateTable("issues") { table in
            table.column("id", .uuid).primaryKey()
                .default(.sql("gen_random_uuid()"))
            table.column("author_id", .uuid).notNull()
                .references("users", column: "id", onDelete: .restrict)
            table.column("title", .varchar(length: 200)).notNull()
            table.column("priority", .integer).notNull().default(0)
            table.column("metadata", .jsonb)
            table.check("issues_priority_nonnegative", sql: "priority >= 0")
            table.timestamps()
        }
        CreateIndex("issues_author_id_index", on: "issues", columns: ["author_id"])
    }
}
```

There is no implicit primary key. Columns are nullable unless marked with `notNull()` or `primaryKey()`. A primary key makes its column nonnullable in PostgreSQL.

``MigrationColumnType`` supports `uuid`, `text`, `varchar(length:)`, `integer`, `bigint`, `boolean`, `timestamptz`, `jsonb`, and `numeric(precision:scale:)`. Use explicit ``SQL`` for types or constructs outside this vocabulary.

``MigrationDefault`` accepts string, integer, floating-point, and boolean literals. A string default stays a quoted literal; `.sql("CURRENT_TIMESTAMP")` explicitly inserts a trusted PostgreSQL expression. Do not pass user input to SQL expressions, checks, or index predicates.

`timestamps()` adds `created_at` and `updated_at` as `TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP`. These are insert-time defaults; the helper does not create an update trigger.

### Name and qualify objects

Identifiers are quoted separately. A dot inside a name is part of the identifier, not a schema separator. Use `schema:` to qualify an object:

```swift
CreateTable("events", schema: "audit") { table in
    table.column("id", .uuid).primaryKey()
    table.column("message", .text).notNull()
}
```

The schema must already exist, or be created by an earlier explicit SQL operation. Spectro does not add `CASCADE` or `IF EXISTS` automatically.

### Add references and indexes

`references(_:schema:column:onDelete:name:)` defaults to the referenced `id` column, `NO ACTION`, and a `table_column_fkey` constraint name. Set `name:` to choose the name explicitly. Supported ``ReferenceAction`` values are `noAction`, `restrict`, `cascade`, `setNull`, and `setDefault`.

Planning rejects `SET NULL` on a nonnullable column and `SET DEFAULT` without a declared default. A reference does not create an index. Add a named ``CreateIndex`` separately:

```swift
CreateIndex("users_active_email_index", on: "users", columns: ["email"])
    .unique()
    .whereSQL("active = TRUE")
```

Indexes use B-tree, accept multiple column names, and support uniqueness and a trusted partial predicate. Composite primary keys, expression indexes, and other PostgreSQL features require explicit SQL.

### Alter a table

```swift
struct ExtendUserProfile: Migration {
    static let id = "1791129602_extend_user_profile"

    var change: MigrationPlan {
        AlterTable("users") { table in
            table.rename("display_name", to: "nickname")
            table.add("bio", .text)
        }
    }
}
```

``AlterTableContext/add(_:_:)`` accepts the same column modifiers as a new table. Automatic rollback drops `bio`, then renames `nickname` back to `display_name`. Both top-level operations and operations inside an alteration reverse their order.

Alterations also remove columns, change types, nullability, and defaults, and add check, unique, and foreign-key constraints, each with an automatic rollback:

```swift
AlterTable("posts") { table in
    table.remove("legacy_slug", .varchar(length: 80)).notNull()
    table.alter("views", type: .bigint, from: .integer)
    table.setNotNull("title")
    table.setDefault("state", .sql("'draft'"), from: nil)
    table.check("posts_views_nonnegative", sql: "views >= 0")
    table.foreignKey("editor_id", references: "users", onDelete: .setNull)
}
RenameTable("posts", to: "articles")
CreateEnum("post_state", values: ["draft", "published"])
```

Rollback of ``AlterTableContext/remove(_:_:)`` adds the column back, described by the modifiers of ``RemovedColumn``, without its data. ``AlterTableContext/dropConstraint(_:)`` and ``DropIndex`` have no inverse and belong in an explicit branch. Columns take ``MigrationColumnType`` values, including arrays and named types such as an enum from ``CreateEnum``.

### Build indexes concurrently

```swift
struct IndexIssueTitles: Migration {
    static let id = "1791129604_index_issue_titles"
    static let runsInTransaction = false

    var change: MigrationPlan {
        CreateIndex("issues_title_index", on: "issues", columns: ["title"]).concurrently()
    }
}
```

PostgreSQL forbids `CONCURRENTLY` in a transaction, so set ``Migration/runsInTransaction`` to `false`, like Ecto's `@disable_ddl_transaction`. Each statement then commits on its own, and a failure leaves the statements before it applied.

For drops, type changes, data changes, or a rollback that needs more context, continue with <doc:RollbackAndSQL>.
