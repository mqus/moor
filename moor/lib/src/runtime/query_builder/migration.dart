part of 'query_builder.dart';

/// Signature of a function that will be invoked when a database is created.
typedef OnCreate = Future<void> Function(Migrator m);

/// Signature of a function that will be invoked when a database is upgraded
/// or downgraded.
/// In version upgrades: from < to
/// In version downgrades: from > to
typedef OnUpgrade = Future<void> Function(Migrator m, int from, int to);

/// Signature of a function that's called before a database is marked opened by
/// moor, but after migrations took place. This is a suitable callback to to
/// populate initial data or issue `PRAGMA` statements that you want to use.
typedef OnBeforeOpen = Future<void> Function(OpeningDetails details);

Future<void> _defaultOnCreate(Migrator m) => m.createAll();
Future<void> _defaultOnUpdate(Migrator m, int from, int to) async =>
    throw Exception("You've bumped the schema version for your moor database "
        "but didn't provide a strategy for schema updates. Please do that by "
        'adapting the migrations getter in your database class.');

/// Handles database migrations by delegating work to [OnCreate] and [OnUpgrade]
/// methods.
class MigrationStrategy {
  /// Executes when the database is opened for the first time.
  final OnCreate onCreate;

  /// Executes when the database has been opened previously, but the last access
  /// happened at a different [GeneratedDatabase.schemaVersion].
  /// Schema version upgrades and downgrades will both be run here.
  final OnUpgrade onUpgrade;

  /// Executes after the database is ready to be used (ie. it has been opened
  /// and all migrations ran), but before any other queries will be sent. This
  /// makes it a suitable place to populate data after the database has been
  /// created or set sqlite `PRAGMAS` that you need.
  final OnBeforeOpen /*?*/ beforeOpen;

  /// Construct a migration strategy from the provided [onCreate] and
  /// [onUpgrade] methods.
  MigrationStrategy({
    this.onCreate = _defaultOnCreate,
    this.onUpgrade = _defaultOnUpdate,
    this.beforeOpen,
  });
}

/// Runs migrations declared by a [MigrationStrategy].
class Migrator {
  final GeneratedDatabase _db;

  /// Function to obtain a [QueryEngine] to run the generated sql statements for
  /// migrations.
  /// If a `transaction` callback is used inside a migration, then we'd have to
  /// run a subset of migration steps on a different query executor. This
  /// function is used to find the correct implementation, usually by looking at
  /// the current zone.
  final QueryEngine Function() _resolveEngineForMigrations;

  /// Used internally by moor when opening the database.
  Migrator(this._db, this._resolveEngineForMigrations);

  /// Creates all tables specified for the database, if they don't exist
  @Deprecated('Use createAll() instead')
  Future<void> createAllTables() async {
    for (final table in _db.allTables) {
      await createTable(table);
    }
  }

  /// Creates all tables, triggers, views, indexes and everything else defined
  /// in the database, if they don't exist.
  Future<void> createAll() async {
    for (final entity in _db.allSchemaEntities) {
      if (entity is TableInfo) {
        await createTable(entity);
      } else if (entity is Trigger) {
        await createTrigger(entity);
      } else if (entity is Index) {
        await createIndex(entity);
      } else if (entity is OnCreateQuery) {
        await issueCustomQuery(entity.sql, const []);
      } else {
        throw AssertionError('Unknown entity: $entity');
      }
    }
  }

  GenerationContext _createContext() {
    return GenerationContext.fromDb(_db);
  }

  /// Creates the given table if it doesn't exist
  Future<void> createTable(TableInfo table) async {
    final context = _createContext();

    if (table is VirtualTableInfo) {
      _writeCreateVirtual(table, context);
    } else {
      _writeCreateTable(table, context);
    }

    return issueCustomQuery(context.sql, context.boundVariables);
  }

  void _writeCreateTable(TableInfo table, GenerationContext context) {
    context.buffer.write('CREATE TABLE IF NOT EXISTS ${table.$tableName} (');

    var hasAutoIncrement = false;
    for (var i = 0; i < table.$columns.length; i++) {
      final column = table.$columns[i];

      if (column is GeneratedIntColumn && column.hasAutoIncrement) {
        hasAutoIncrement = true;
      }

      column.writeColumnDefinition(context);

      if (i < table.$columns.length - 1) context.buffer.write(', ');
    }

    final dslTable = table.asDslTable;

    // we're in a bit of a hacky situation where we don't write the primary
    // as table constraint if it has already been written on a primary key
    // column, even though that column appears in table.$primaryKey because we
    // need to know all primary keys for the update(table).replace(row) API
    final hasPrimaryKey = table.$primaryKey?.isNotEmpty ?? false;
    final dontWritePk = dslTable.dontWriteConstraints || hasAutoIncrement;
    if (hasPrimaryKey && !dontWritePk) {
      context.buffer.write(', PRIMARY KEY (');
      final pkList = table.$primaryKey.toList(growable: false);
      for (var i = 0; i < pkList.length; i++) {
        final column = pkList[i];

        context.buffer.write(column.$name);

        if (i != pkList.length - 1) context.buffer.write(', ');
      }
      context.buffer.write(')');
    }

    final constraints = dslTable.customConstraints ?? [];

    for (var i = 0; i < constraints.length; i++) {
      context.buffer..write(', ')..write(constraints[i]);
    }

    context.buffer.write(')');

    // == true because of nullability
    if (dslTable.withoutRowId == true) {
      context.buffer.write(' WITHOUT ROWID');
    }

    context.buffer.write(';');
  }

  void _writeCreateVirtual(VirtualTableInfo table, GenerationContext context) {
    context.buffer
      ..write('CREATE VIRTUAL TABLE IF NOT EXISTS ')
      ..write(table.$tableName)
      ..write(' USING ')
      ..write(table.moduleAndArgs)
      ..write(';');
  }

  /// Executes the `CREATE TRIGGER` statement that created the [trigger].
  Future<void> createTrigger(Trigger trigger) {
    return issueCustomQuery(trigger.createTriggerStmt, const []);
  }

  /// Executes a `CREATE INDEX` statement to create the [index].
  Future<void> createIndex(Index index) {
    return issueCustomQuery(index.createIndexStmt, const []);
  }

  /// Deletes the table with the given name. Note that this function does not
  /// escape the [name] parameter.
  Future<void> deleteTable(String name) async {
    return issueCustomQuery('DROP TABLE IF EXISTS $name;');
  }

  /// Adds the given column to the specified table.
  Future<void> addColumn(TableInfo table, GeneratedColumn column) async {
    final context = _createContext();

    context.buffer.write('ALTER TABLE ${table.$tableName} ADD COLUMN ');
    column.writeColumnDefinition(context);
    context.buffer.write(';');

    return issueCustomQuery(context.sql);
  }

  /// Executes the custom query.
  Future<void> issueCustomQuery(String sql, [List<dynamic> args]) async {
    await _resolveEngineForMigrations().doWhenOpened(
      (executor) => executor.runCustom(sql, args),
    );
  }
}

/// Provides information about whether migrations ran before opening the
/// database.
class OpeningDetails {
  /// The schema version before the database has been opened, or `null` if the
  /// database has just been created.
  final int versionBefore;

  /// The schema version after running migrations.
  final int versionNow;

  /// Whether the database has been created during this session.
  bool get wasCreated => versionBefore == null;

  /// Whether a schema upgrade was performed while opening the database.
  bool get hadUpgrade => !wasCreated && versionBefore != versionNow;

  /// Used internally by moor when opening a database.
  const OpeningDetails(this.versionBefore, this.versionNow);
}
