# Troubleshooting Swift migrations

Resolve setup, planning, configuration, and artifact problems.

## Overview

### The CLI does not recognize init or plan

Run `spectro --version` and use the 2.1 CLI. The 2.0 CLI supports the SQL workflow only. For development against a local checkout, build its `spectro` product and put the reported binary directory on your shell's `PATH`.

### No Swift migrations are configured

Run `spectro migrate init --target MyAppMigrations` in the application package. Keep `.spectro.json` beside `Package.swift`; discovery stops at the nearest package boundary. Add the target declaration printed by initialization, and make its product name match the descriptor.

If SwiftPM fails while showing help, use `spectro help migrate <command>` to read the launcher's help without building the application.

### A declaration is missing or empty

Add the migration instance to ``MigrationRegistry`` in `Migrations.swift`. Files are not discovered automatically. Fill the generated `change` body before planning; a registered empty migration is rejected.

``/SpectroCommon/MigrationPlanningError`` includes the migration ID, an operation index when available, and a reason. Operation indexes are zero-based. Fix the declaration rather than changing an already-applied ID. Duplicate IDs across Swift and SQL sources also fail planning.

### Credentials are missing despite an env file

The project executable reads exported process environment, not `.env` files. Set `DB_USER`, `DB_PASSWORD`, and `DB_NAME`, pass credential options, or supply a configuration provider. Planning and help do not require credentials. See <doc:CommandsAndConfiguration> for the separate legacy SQL CLI policy.

### SQL resources disappear after deployment

Declare `.copy("LegacySQL")` in the target, register ``SQLMigrations`` using `.module`, and copy all generated resource bundles beside the executable. Test the copied artifact outside the source checkout. A missing resource directory is an error even if its migrations were already applied.

### A down preview is irreversible

A whole-catalog down preview includes every registered migration. Inspect a specific reversible ID with `plan --migration <full-id> --direction down`. Actual rollback selects completed database history; preview selection does not override that selection or make an irreversible migration reversible.

### Rollback reports missing history

Deploy an artifact that contains the applied IDs. Preserve old filenames, declarations, and resources. The runner preflights the whole selected batch and does not skip missing IDs. Remember that omitting `--step` selects all completed migrations.

### The migration lock times out

Check for another migration process and ensure the connection is direct or session-pooled. The default lock timeout is 30 seconds. A transaction-pooling proxy cannot maintain the session used for locking. See <doc:Deployment> for lifecycle and transaction behavior.

### Plan succeeds but PostgreSQL rejects the change

Planning validates declarations and SQL statement boundaries without consulting the database. PostgreSQL checks SQL syntax, referenced objects, permissions, existing rows, and constraints at execution. Raw SQL must be compatible with the migration's transaction; for example, `CREATE INDEX CONCURRENTLY` runs only in a migration whose ``Migration/runsInTransaction`` is `false`.
