# ``SpectroMigrations``

Declare PostgreSQL migrations in Swift and ship them as your application's executable.

## Overview

Spectro 2.1 adds an optional migration library inspired by Ecto. A historical declaration describes its changes, the compiler produces PostgreSQL statements and rollback, and an explicit registry defines the executable's complete history. Existing SQL files can join the same registry without changing their IDs.

During development, `spectro` scaffolds files and launches your target through SwiftPM. In production, run the compiled executable with its resource bundles and runtime libraries. The application and its migration target share one package and dependency resolution.

```swift
import SpectroMigrations

struct CreateUsers: Migration {
    static let id = "1791129600_create_users"

    var change: MigrationPlan {
        CreateTable("users") { table in
            table.column("id", .uuid).primaryKey()
                .default(.sql("gen_random_uuid()"))
            table.column("email", .text).notNull()
            table.column("display_name", .text)
            table.column("active", .boolean).notNull().default(true)
            table.timestamps()
        }
        CreateIndex("users_email_index", on: "users", columns: ["email"]).unique()
    }
}
```

Rollback drops the index before the table. For destructive changes, write the reverse explicitly or explain why the change is irreversible.

## Topics

### Learn Swift migrations

- <doc:GettingStarted>
- <doc:DeclaringChanges>
- <doc:RollbackAndSQL>
- <doc:AdoptingSQL>
- <doc:CommandsAndConfiguration>
- <doc:Deployment>
- <doc:Troubleshooting>

### Declare a migration

- ``Migration``
- ``MigrationPlan``
- ``MigrationStep``
- ``CreateTable``
- ``AlterTable``
- ``RenameTable``
- ``CreateIndex``
- ``CreateEnum``

### Define columns and constraints

- ``TableDefinitionContext``
- ``AlterTableContext``
- ``RemovedColumn``
- ``ColumnDefinition``
- ``MigrationColumnType``
- ``MigrationDefault``
- ``ReferenceAction``

### Control rollback

- ``Reversible``
- ``Irreversible``
- ``SQL``
- ``DropTable``
- ``DropIndex``

### Register, compile, and run

- ``MigrationRegistry``
- ``SQLMigrations``
- ``MigrationCompiler``
- ``MigrationCommand``

### Result builders

- ``MigrationBuilder``
- ``MigrationRegistryBuilder``
- ``TableBuilder``
- ``AlterTableBuilder``
- ``MigrationEntries``
- ``TableElements``
- ``TableAlterations``
