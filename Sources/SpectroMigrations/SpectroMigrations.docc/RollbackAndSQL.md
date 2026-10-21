# Rollback and explicit SQL

Use automatic inversion for structural changes and explicit branches when history needs more information.

## Overview

### Understand automatic rollback

| Change | Automatic rollback |
|---|---|
| Create a table | Drop the table |
| Create an index | Drop the index |
| Add a column | Drop the column |
| Rename a column | Rename it back |

Rollback reverses the order of top-level operations and changes inside ``AlterTable``. Dropping a table or column removes its data. Recreating its shape does not recover its former rows.

### Supply both directions

Use paired ``SQL`` statements for features outside the typed DSL:

```swift
struct AddEmailConstraint: Migration {
    static let id = "1791129603_add_email_constraint"

    var change: MigrationPlan {
        SQL(
            up: "ALTER TABLE users ADD CONSTRAINT users_email_present CHECK (btrim(email) <> '')",
            down: "ALTER TABLE users DROP CONSTRAINT users_email_present"
        )
    }
}
```

Use ``Reversible`` to describe separate groups of operations:

```swift
struct ReplaceLegacyLabels: Migration {
    static let id = "1791129604_replace_legacy_labels"

    var change: MigrationPlan {
        Reversible {
            DropTable("legacy_labels")
        } down: {
            CreateTable("legacy_labels") { table in
                table.column("name", .text).notNull()
            }
        }
    }
}
```

Each explicit branch executes its operations forward, in declaration order. A `CreateTable` in a down branch creates a table. A paired `SQL(up:down:)` there executes its `up` script. A nested `Reversible` selects the enclosing direction; its chosen branch is not inverted a second time.

This example restores only the `legacy_labels` schema. If the rows must survive, write and test the required data preservation strategy as part of the migration.

### Declare irreversible changes

```swift
struct NormalizeEmail: Migration {
    static let id = "1791129605_normalize_email"

    var change: MigrationPlan {
        Irreversible("The original spelling of email addresses is not retained") {
            SQL("UPDATE users SET email = lower(email)")
        }
    }
}
```

``Irreversible`` requires a nonempty reason and makes the whole migration irreversible. A selected rollback batch containing it fails preflight before any migration in that batch changes the database.

An unpaired `SQL("...")` or ``DropTable`` requires an explicit branch. Empty branches are rejected. `Irreversible` cannot appear inside an explicit down branch.

### Stay within one transaction

Raw SQL runs in the same per-migration transaction as typed operations and the ledger update. Prepared migrations reject transaction-control statements such as `BEGIN`, `COMMIT`, and `ROLLBACK`. `CREATE INDEX CONCURRENTLY` needs a migration whose ``Migration/runsInTransaction`` is `false`; otherwise PostgreSQL rejects it and that migration rolls back.

The statement parser preserves dollar-quoted function bodies, escape strings, quoted identifiers, nested comments, and SQL line-comment boundaries. Planning checks the migration structure and statement boundaries. PostgreSQL still validates SQL syntax, permissions, and schema references at execution.

### Preview the selected direction

```sh
spectro migrate plan --direction down
spectro migrate plan --migration 1791129603_add_email_constraint --direction down
spectro migrate down --step 1
```

`plan` is an offline view of registered history, regardless of which migrations are applied. A whole-catalog down preview fails if any registered migration is irreversible. Selecting one ID lets you inspect that migration; it does not change the batch selected by a later `down` command.

Actual rollback starts from completed database history in descending full-ID order. Missing or irreversible IDs in the selected batch stop the command before executing DDL. Omitting `--step` selects all completed migrations; `--step 0` is a no-op and negative values are rejected.
