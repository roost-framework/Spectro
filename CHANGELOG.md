# Changelog

## Unreleased

- Add `orderBy(sql:_:)` to `Query` and `TupleQuery`, to sort by an `SQLFragment`. Fragment and field sorts keep call order, and the fragment's parameters bind after the filters'. `count()`, aggregates, and direct bulk writes drop the ordering with its parameters.
- Add `Repo.executeRawQuery(_:)`, like Ecto's `Repo.query`, to run a statement written as an `SQLFragment`, with its placeholders numbered.
- Add `Query.distinct()` and `Query.distinct(_:)` for `DISTINCT` and `DISTINCT ON`, and `TupleQuery.distinct()`. DISTINCT ON columns the ordering does not start with are sorted first, as Ecto does. `count()` and aggregates count each distinct row once.
- Add subqueries: `in(_:)` and `notIn(_:)` take a single-column `TupleQuery`, and `QueryCondition.exists(_:)` takes a `Query`, correlated through the outer query's fields. Add `Query.exists()`, like Ecto's `Repo.exists?`.
- Compare columns with columns: `==`, `!=`, `<`, `<=`, `>`, and `>=` between `QueryField`s, including nullable with nonnullable.
- Add `union`, `unionAll`, `intersect`, `intersectAll`, `except`, and `exceptAll`. Each query keeps its filters, joins, ordering, and limit; clauses added to the result apply to the combined rows.
- Add `Query.recursive(_:)`, a `WITH RECURSIVE` query that follows rows from the query's rows, such as a tree's descendants or ancestors. It skips soft-deleted rows and ends on cycles.
- Select SQL expressions with `QueryBuilder.expression(_:as:)`, such as aggregates and window functions, alongside columns: `select` takes any `Selection`, a `QueryField` of a `DatabaseValue` type or an `SQLExpression`. A projection of a query with `groupBy` and `having` is now grouped, one result per group, and its `count()` counts the groups; the grouping was ignored.
- Declare nullable foreign keys with `@ForeignKey var editorId: UUID?`. `ForeignKey` now takes a `ForeignKeyValue`: a `PrimaryKeyType`, or an `Optional` of one. A nil key stores NULL and preloads no record.
- Add `Changeset.castAssoc` for has-many and has-one relationships, like Ecto's `cast_assoc`. Nested params become changesets of the loaded or new related records, which inserting or updating the changeset writes with their foreign key in one transaction, returning the record with the relationship loaded. Related errors join as `"posts[1].title"`, and `OnReplace` decides what happens to loaded records the params leave out. `Changeset.errors` has an internal setter instead of a private one.
- Add `Changeset.prepareChanges(_:)`, like Ecto's `prepare_changes`: a function that runs in the write's transaction just before it, and is skipped for an invalid changeset.
- Add `Changeset.optimisticLock(_:)`, like Ecto's `optimistic_lock`. An update increments the integer version field and matches the row only while it holds the loaded version; otherwise it throws the new `SpectroError.staleRecord`. Add `staleRecord` to exhaustive `SpectroError` switches.
- Extend the migration DSL. `AlterTable` removes columns, changes types, nullability, and defaults, and adds check, unique, and foreign-key constraints, each with an automatic rollback; `dropConstraint` belongs in an explicit branch. Add `RenameTable`, `CreateEnum`, `DropIndex`, and `CreateIndex.concurrently()`, and the column types `smallint`, `real`, `doublePrecision`, `date`, `timestamp`, `bytea`, `json`, `array(_:)`, and `named(_:schema:)`. Add the new cases to exhaustive `MigrationColumnType` switches.
- Run a migration outside a transaction, for `CREATE INDEX CONCURRENTLY`, like Ecto's `@disable_ddl_transaction`: set `Migration.runsInTransaction` to `false`, or start a SQL file with `-- migrate:up transaction:false`, as in dbmate. `PreparedMigration` gains `runsInTransaction`.
- Add `transaction(isolation:_:)` to `GenericDatabaseRepo`, `Spectro`, and `DatabaseConnection`, with `TransactionIsolation` levels `readCommitted`, `repeatableRead`, and `serializable`.
- Add `insertAll(_:onConflict:includePrimaryKey:)` and `insert(_:onConflict:includePrimaryKey:)` with `ConflictAction.nothing(on:)` and `.replace(on:columns:)`, like Ecto's `on_conflict`. They return the records inserted or updated.
- Add `Repo.reload(_:)` for one record or many, in one query, like Ecto's `Repo.reload`.
- Add `Query.batches(of:)`, an `AsyncSequence` of primary key batches for reading large results, like Ecto's `Repo.stream`.
- Add `DatabaseValue`, Spectro's counterpart of `Ecto.Type`. `@Column`, filters, changesets, selections, and updates accept any conforming type. Built in: `Decimal` (`numeric`), `Data` (`bytea`), arrays of conforming types (`text[]`, `uuid[]`, `integer[]`, …), `[String: Value]` dictionaries (`jsonb`), and `Optional`s of all of them. Conform a raw-value enum to store its raw value; a `String` raw value fits text, varchar, and PostgreSQL enum columns. Conform a `Codable` type to `JSONBValue` to store it as `jsonb`. Implement `toPostgresData()`, `fromPostgresData(_:)`, and optionally `cast(_:)` for other types. `PrimaryKeyType` now refines `DatabaseValue`; existing conformances keep compiling.
- `@Column` requires a `DatabaseValue` type. Properties of other types compiled but were silently neither stored nor decoded; conform the type, or store it in a plain property.
- Add `FieldType.custom` and `FieldInfo.valueType`. Add `custom` to exhaustive switches over `FieldType`.
- Decode `String` columns of extension and user-defined types, such as `citext` and PostgreSQL enums. They decoded as missing values.
- Register `@Column` properties of type `Data`. They were neither inserted nor decoded.
- Add array filters `contains(_:)` (`= ANY`), `containsAll(_:)` (`@>`), and `overlaps(_:)` (`&&`). The latter two cast the column to the bound array type, so `[Int]` filters `integer[]` columns and `[String]` filters `varchar[]` and PostgreSQL enum arrays; the cast is free, and keeps GIN indexes usable, when the types match.
- `Decimal` holds 38 significant digits: decoding a longer `numeric` fails instead of rounding, encoding NaN throws instead of trapping in PostgresNIO, and changesets reject strings such as `"1,000"` or `"12 USD"` instead of reading their numeric prefix.
- Add `QueryCondition.fragment(_:)` and `SQLFragment`, like Ecto's `fragment`. Interpolated fields become qualified columns, interpolated values become bound parameters, and a literal `?`, such as the `jsonb` operator, stays in the SQL. Use fragments in `where` and `having`.
- Add `QueryBuilder.table(_:as:)` to filter on a joined table's columns.
- Add `Query.updateAll(_:)` and `Query.deleteAll()`, like Ecto's `update_all` and `delete_all`. They return the number of affected rows. Assignments are `set(_:)`, `set(sql:)`, `increment(by:)`, `push(_:)`, and `pull(_:)`. Joins, ordering, limits, and offsets select the affected rows. `deleteAll()` marks rows of `@SoftDelete` schemas as deleted, as `delete` does.
- Add `Query.lock(_:_:)` for `FOR UPDATE`, `FOR NO KEY UPDATE`, `FOR SHARE`, and `FOR KEY SHARE`, with `NOWAIT` or `SKIP LOCKED`. Only the queried table's rows are locked.
- Preload relationships of preloaded records, and customize the query that loads a relationship: `.preload(\.$posts) { $0.where { … }.orderBy { … }.preload(\.$comments) }`. Many-to-many preloads keep the related query's order.
- Add `Repo.preload(_:_:)` for records already fetched, in one query for all of them, also inside transactions.
- Preload belongs-to relationships through nullable foreign key columns such as `@Column var editorId: UUID?`. Accept a preload's `foreignKey:` as a property or a column name; a column name loaded no records. Match many-to-many keys of any `PrimaryKeyType`.
- Add `logger` and `onQuery` to `DatabaseConfiguration`. The logger receives a debug message for each statement with its SQL, rows, and timings, and never its bound values. `onQuery` receives a `QueryEvent` with the SQL, parameters, query time, queue time, row count, and error of each statement, including `BEGIN`, `COMMIT`, and `ROLLBACK`.
- Add `Spectro.sandbox(_:)`, like Ecto's SQL sandbox. It runs its body in a transaction that is always rolled back. Every repository of the instance, in the body and the tasks that inherit its task-local values, uses that transaction. `transaction` becomes a savepoint that holds the connection until it ends. Each statement outside a transaction runs in its own savepoint, so a failed one, such as an expected unique violation, leaves the sandbox usable. Statements from a `Task { }` that outlives the sandbox throw instead of reaching the database.
- A transaction's repository and `TransactionContext` throw `SpectroError.noActiveTransaction` once the transaction has ended. A repository captured by a task that outlived the transaction ran its statements on the released connection, outside any transaction.
- Insert a record with no inserted columns using `DEFAULT VALUES`. It trapped. `upsert` and `insertAll` without columns throw `SpectroError.invalidSchema`; they trapped or sent invalid SQL.
- Throw from inserts, upserts, and `SchemaMapper.extractData`, now `throws`, when a value cannot be encoded. The column was silently left out.
- Size `insertAll` batches to stay under PostgreSQL's 65535 parameters for tables with more than 65 columns.
- Key `SchemaRegistry` by type identity. Two schema types with the same name, such as nested types in different enclosing types, shared metadata.
- Throw `SpectroError.resultDecodingFailed` for a non-NULL value a field's type cannot decode, such as an unknown enum label or JSON of another shape. The field silently kept its default, which a later save wrote back.
- Decode models selected with `selectFields` from a subset of their columns; the other fields keep their defaults. Decoding trapped. Decoding any other result that lacks a model's column throws `SpectroError.resultDecodingFailed` instead of trapping.
- Share one implementation of CRUD between `GenericDatabaseRepo` and `TransactionRepo`.

## 2.6.0 — 2026-10-19

- Add explicit aliases to joins and typed joined reads, including self joins and repeated tables. Select a joined occurrence with `executeJoin(with:as:)`; nullable join keys can be compared with nonnullable keys. Duplicate, invalid, and missing alias references fail before execution. Preserve the original join overloads so existing method references still compile.
- Add opt-in `Changeset.uniqueConstraint`, `foreignKeyConstraint`, and `checkConstraint` declarations. Matching database failures become `SpectroError.changesetFailed` with structured `fieldErrors`, while retaining `serverError`. Match exact database names, SQLSTATE, and the reported table; `onTable:` explicitly accepts another origin such as a partition. Undeclared failures and existing local validation behavior are unchanged.
- Add `statement()`, `explain()`, and `timedAll()` to model queries, projections, and typed joins. Inspect bound parameters separately from SQL, request plain PostgreSQL EXPLAIN, or measure one execution including decoding. These operations use the query's executor, including inside transactions.
- Qualify `Query<T>` fields with their owning table in filters, ordering, selections, grouping, and aggregates. Joined tables with overlapping column names could make these operations fail with an ambiguous-column error, including with custom column names and soft deletes. Filters and ordering also retain their owning table when a join is added later.
- Add PostgreSQL integration coverage combining custom column names, soft deletes, joined reads, aggregates, restoration, transactions, and savepoints, including restoration conflicts and rollbacks after a nested savepoint has been released.
- Highlight the 2.4.0 update/restore migration in the README.
- Report 2.6.0 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.6.0, and require 2.6.0 in the package installation examples. Add `changesetFailed` to exhaustive `SpectroError` switches when upgrading.

[Full comparison with 2.5.0](https://github.com/roost-framework/Spectro/compare/2.5.0...2.6.0)

## 2.5.0 — 2026-10-17

- Add `TransactionRepo.savepoint(_:)`. A failed statement aborts the enclosing PostgreSQL transaction, so every later statement failed with SQLSTATE 25P02. `savepoint` releases the savepoint when its body returns, and rolls back to it when the body throws, rethrowing the body's error unchanged, so the transaction stays usable. Savepoints nest. `transaction()` on a `TransactionRepo` still throws `transactionAlreadyStarted`.
- Add `SpectroError.serverError`, which returns a `DatabaseServerError` with the PostgreSQL error's SQLSTATE, message, constraint, table, column, and detail. It unwraps `transactionFailed`, `transactionAndRollbackFailed`, `queryExecutionFailed`, `invalidSql`, `migrationFailed`, and `connectionFailed`, and reads both PostgresNIO error types. It returns `nil` when the server reported no error.
- Add `Schema.column(for:)`, which returns the database column for a key path, with the snake_case convention and `@Column` and `@ForeignKey` names applied. Use it instead of `_keyPathToColumn`, which holds Swift property names.
- Fix query builders ignoring `@Column("x")` and `@ForeignKey("x")` names. Filters, ordering, selection, grouping, aggregates, and join conditions used the snake_cased property name, so with `@Column("display_name") var name`, `.where { $0.name == "a" }` queried a `name` column. Inserts and decoding already used the custom names. Every earlier release is affected.
- Correct the `TransactionRepo` documentation: `query()` runs inside transactions.
- Report 2.5.0 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.5.0, and require 2.5.0 in the package installation examples.

[Full comparison with 2.4.0](https://github.com/roost-framework/Spectro/compare/2.4.0...2.5.0)

## 2.4.0 — 2026-10-17

- Add `restore(_:id:)` to `Repo`. It clears a soft-deleted record's deletion timestamp and returns the record, returns a record that is not deleted unchanged, and throws `SpectroError.notFound` for an unknown id.
- Add `get(_:id:withDeleted:)` to `Repo`. With `withDeleted: true` it returns soft-deleted records too, like `Query.withDeleted()`. Both additions are protocol extensions, so custom `Repo` conformances keep compiling.
- `update(_:id:changes:)` and changeset updates now treat soft-deleted records as missing, as `get` does. They modified soft-deleted records and returned them as if they were active. An update that matches no record now throws `SpectroError.notFound` instead of `SpectroError.databaseError`. If you revive records by setting their deletion timestamp to `nil` through `update`, call `restore` instead.
- Report 2.4.0 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.4.0, and require 2.4.0 in the package installation examples.

[Full comparison with 2.3.3](https://github.com/roost-framework/Spectro/compare/2.3.3...2.4.0)

## 2.3.3 — 2026-10-17

- Exclude soft-deleted records of joined tables from `join`, `leftJoin`, `rightJoin`, and `joinThrough`. Only the queried table's soft-delete filter was applied, so joins returned the joined table's soft-deleted records and typed left joins decoded them, while `preload` and lazy relations on the same models excluded them. `.withDeleted()` still includes them. Every release since soft deletes were added in 2.0.0 is affected.
- Report 2.3.3 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.3, and require 2.3.3 in the package installation examples.

[Full comparison with 2.3.2](https://github.com/roost-framework/Spectro/compare/2.3.2...2.3.3)

## 2.3.2 — 2026-10-11

- Exclude soft-deleted records from `sum`, `avg`, `min`, `max`, their `grouped` forms, and `select`. These read the query's filters without the automatic soft-delete filter, so `select` returned soft-deleted records' values and aggregates counted them, while `all()` and `count()` on the same query excluded them. `.withDeleted()` still includes them. Every release since soft deletes were added in 2.0.0 is affected.
- Report 2.3.2 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.2, and require 2.3.2 in the package installation examples.

[Full comparison with 2.3.1](https://github.com/roost-framework/Spectro/compare/2.3.1...2.3.2)

## 2.3.1 — 2026-10-11

- Fix queries that combine `||` with other filters returning rows those filters should exclude. `Query.where` joined clauses with a bare `AND`, so `.where { $0.a == x || $0.b == y }.where { $0.ownerID == me }` ran as `a = x OR (b = y AND owner_id = me)` and returned other owners' rows matching `a`. The automatic soft-delete filter was combined the same way, so a single `||` condition also returned soft-deleted rows. Each `where` and `having` clause is now parenthesized. Every earlier release is affected; upgrade if any query combines `||` with an ownership, tenant, or authorization filter.
- Report 2.3.1 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.1, and require 2.3.1 in the package installation examples.

[Full comparison with 2.3.0](https://github.com/roost-framework/Spectro/compare/2.3.0...2.3.1)

## 2.3.0 — 2026-10-07

- Put Noora behind a new `RichTerminal` package trait, on by default with `CLI` and `Migrations`. With only `CLI` enabled, the `spectro` command prints plain text: alerts with their takeaways, progress steps, a `[y/N]` confirmation, and aligned tables. Roost enables only `CLI`, so `roost spectro` keeps working without fetching Noora.
- CI builds the `spectro` command without Noora.
- Report 2.3.0 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.3.0.

[Full comparison with 2.2.0](https://github.com/roost-framework/Spectro/compare/2.2.0...2.3.0)

## 2.2.0 — 2026-10-07

- Put the `spectro` command's dependencies (ArgumentParser and Noora) behind the `CLI` package trait, and SpectroMigrations' ArgumentParser dependency behind the `Migrations` trait. Both are on by default. A package that only uses SpectroKit, such as a framework built on Spectro, can depend on it with `traits: []`; SwiftPM then skips fetching those tools' dependencies.
- Require Swift 6.1 (swift-tools-version 6.1), the first version with package traits. Swift 6.0 projects keep resolving Spectro 2.1.x.
- Report 2.2.0 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.2.0.

[Full comparison with 2.1.1](https://github.com/roost-framework/Spectro/compare/2.1.1...2.2.0)

## 2.1.1 — 2026-10-06

- Depend on swift-syntax through its canonical `swiftlang/swift-syntax` URL. Packages that also depend on ESW no longer get SwiftPM's conflicting-identity warning, which future SwiftPM versions turn into an error.
- Report 2.1.1 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.1.1.

[Full comparison with 2.1.0](https://github.com/roost-framework/Spectro/compare/2.1.0...2.1.1)

## 2.1.0 — 2026-10-06

- Add the optional `SpectroMigrations` product: deterministic Swift declarations, PostgreSQL compilation, explicit registration, reversible schema operations, references/checks, and explicit SQL/irreversible branches.
- Ship a project-owned migration executable with offline `plan`, lazy database configuration, bundled SQL history, and strict rollback preflight for missing or irreversible history.
- Add `spectro migrate init`, configured Swift migration generation, and project-aware command forwarding with exit-status and signal propagation.
- Stop package discovery at the filesystem root so SQL migration commands also work outside Swift packages on macOS.
- Share the existing session lock and transactional engine through `MigrationRunner`; retain `MigrationManager` and the legacy SQL CLI APIs.
- Fix statement splitting for quoted identifiers, PostgreSQL escape strings, bind parameters, and nested comments.
- Add copied release-artifact and compiler-free Linux deployment acceptance, plus a compiled migration scenario in the HTTP example.
- Document Swift target setup, explicit registration, SQL adoption, exported configuration, and compiled deployment; expand launcher and project-executable help with examples, preview options, and rollback defaults.
- Add a merged DocC website with guides and API navigation for Spectro, SpectroMigrations, and SpectroCommon; build and check it with `python3 scripts/build_docs.py`.
- Report the CLI release version with `spectro --version` and pin installation examples and the Mintfile to 2.1.0.

Existing `SpectroKit` consumers need no additional product dependency or protocol changes. The minor version reflects an additive public surface. See the [upgrade guide](docs/UPGRADING-2.1.md) and [migration guide](docs/MIGRATIONS.md).

[Full comparison with 2.0.0](https://github.com/roost-framework/Spectro/compare/2.0.0...2.1.0)

## 2.0.0 — 2026-10-04

Spectro 2.0 focuses on PostgreSQL correctness and application-level validation. It also includes the changeset, pagination, and soft-delete APIs added since 1.2.0.

### Breaking changes

- Custom `Repo` conformers must implement `insert(_ changeset:)` and `update(_ changeset:)`. Spectro's built-in repositories already implement both requirements, including inside transactions.
- Model-returning right joins now throw because their result types cannot represent an absent main model. Reverse the query and use a left join. Typed self joins and repeated tables are rejected until table aliases are supported; typed left joins require a nonnullable primary key on the joined schema.
- Typed joined reads now throw when a present row cannot be decoded, instead of substituting default values or silently omitting it.
- Migration runners require a direct or session-pooled connection and transaction-compatible SQL. Use the 2.0 runner consistently when multiple processes can migrate the same database.

See the [upgrade guide](docs/UPGRADING-2.0.md) for migration examples and operational changes.

### Added

- Changesets with permitted-field casting, validators, serializable errors, uniqueness checks, and repository insert/update support.
- `Query.page(size:page:)` with total counts and navigation metadata.
- Opt-in soft deletes with `@SoftDelete` and `.withDeleted()`.
- A public-API IssueTracker HTTP application and repeatable acceptance command covering transactions, joined reads, competing writes, populated migrations, rollback/reapply, and restart persistence.

### Fixed

- `@Schema` recognizes `@SoftDelete`, generates filtering metadata, and preserves deletion timestamps in decoded models and JSON.
- Migration SQL and status recording now use the same transaction. Competing migration commands serialize through a PostgreSQL advisory lock, with bounded lock waiting and cancellation cleanup.
- Joined models decode from separate projections, preserving IDs, timestamps, custom column mappings, and nullable fields without column collisions. An unmatched left-joined model is `nil`.
- Query parameters follow SQL order across joins, filters, and HAVING clauses; soft-delete filters are qualified in joined queries.
- Changeset casting rejects invalid field types and non-finite numbers before persistence. Both repositories honor custom column names.
- Recursive error formatting no longer crashes when reporting `SpectroError`; transaction failures preserve the original error after successful rollback.
- Database connections honor configured TLS settings and reject invalid settings before allocating event-loop threads.
- Fresh-database migration commands initialize their tracking state, while migration status remains read-only.
- CI propagates test failures. Acceptance build artifacts use a local cache to avoid macOS signing failures caused by Finder metadata in cloud-synced folders.

### Compatibility and validation

- Spectro requires Swift 6.0+ and supports macOS 13+ and Linux with PostgreSQL.
- The core suite contains 368 tests, including concurrent migration processes, cancellation, and macro-defined soft deletes. CI runs PostgreSQL-backed tests on macOS and Linux.
- Building the IssueTracker acceptance application requires Swift 6.3+ and an Xcode 26.3+ SDK on a compatible host (macOS 15.6+ for Xcode 26.3); its package deployment target is macOS 14. Its pinned Peregrine 1.2.0 dependency currently prevents that example from building on Linux; Spectro's core Linux support is unaffected.

[Full comparison with 1.2.0](https://github.com/roost-framework/Spectro/compare/1.2.0...2.0.0)
