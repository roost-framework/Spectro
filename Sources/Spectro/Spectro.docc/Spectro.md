# ``Spectro``

Map Swift models to PostgreSQL with schemas, changesets, composable queries, and transactions.

## Overview

Spectro is a Swift 6 ORM inspired by Elixir's Ecto. Add the `SpectroKit` package product and `import Spectro` in application code. Use a shared client for connection pooling, define models with the schema macro, and pass repositories to database operations.

Spectro 2.1 also offers the optional `SpectroMigrations` product for compiled Swift migrations. Existing SQL migration directories and the ``MigrationManager`` API continue to work.

## Topics

### Learn Spectro

- <doc:GettingStarted>
- <doc:SchemasAndChangesets>
- <doc:QueriesAndRelationships>
- <doc:TransactionsAndConfiguration>
- <doc:SQLMigrations>

### Connect and persist

- ``Spectro/Spectro``
- ``SpectroClient``
- ``DatabaseConfiguration``
- ``DatabaseConnection``
- ``Repo``
- ``GenericDatabaseRepo``
- ``ConflictTarget``

### Define a schema

- ``Schema(_:)``
- ``Schema(_:encodable:)``
- ``Schema``
- ``SchemaBuilder``
- ``ID``
- ``Column``
- ``Timestamp``
- ``SoftDelete``
- ``PrimaryKeyType``
- ``DatabaseValue``
- ``JSONBValue``

### Validate changes

- ``Changeset``
- ``ChangesetErrors``

### Build queries

- ``Query``
- ``QueryBuilder``
- ``QueryField``
- ``QueryCondition``
- ``SQLFragment``
- ``FieldAssignment``
- ``RowLockStrength``
- ``RowLockWait``
- ``JoinQuery``
- ``PreloadQuery``
- ``ModelQuery``
- ``PreloadCustomization``
- ``Page``
- ``GroupedResult``
- ``QueryStatement``
- ``TimedQueryResult``

### Load relationships

- ``ForeignKey``
- ``HasMany``
- ``HasOne``
- ``BelongsTo``
- ``ManyToMany``
- ``SpectroLazyRelation``
- ``RelationshipInfo``

### Execute transactions

- ``TransactionRepo``
- ``TransactionContext``
- ``QueryExecutor``
- ``QueryEvent``
- ``QueryObserver``

### Run migrations

- ``MigrationManager``
- ``MigrationCatalog``
- ``MigrationRunner``

### Inspect metadata and errors

- ``SchemaRegistry``
- ``SchemaMetadata``
- ``FieldInfo``
- ``FieldType``
- ``SpectroError``
