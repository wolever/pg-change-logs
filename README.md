# `change_logs.sql` automatically manages audit logs for Postgres databases

`change_logs.sql` creates the tables, triggers, and functions necessary to
automatically manage audit logs for selected tables (and columns) in Postgres
databases.


Change tracking is enabled with `change_logs_track_table`:

```sql
select change_logs_track_table(
    _table => 'todo_list_items',
    _pk_col => 'id',
    _cols => array['*', '-created_at', '-updated_at'],
    _indexed_cols => array['user_id']
);
```

Which sets up triggers to log all changes to the `change_logs` table.

Additionally, context (such as user ID, API endpoint, span/trace ID, etc.) can
be included:

```sql
> select change_logs_set_context(_user_id => 99, _context_str => '{"endpoint": "post_todo_list_items"}');
> insert into todo_list_items (user_id, title) values (42, 'Buy milk');
> update todo_list_items set title = 'Buy milk and eggs';
> update todo_list_items set user_id = 16;
> select * from change_logs;
 id |       tbl       | pk |             ts             | user_id |          old           |                      new                      |           indexed           |              context
----+-----------------+----+----------------------------+---------+------------------------+-----------------------------------------------+-----------------------------+-------------------------------------
  7 | todo_list_items | 1  | 2024-07-07 17:14:01.445071 |      99 |                        | {"id": 1, "title": "Buy milk", "user_id": 42} | {{user_id,42}}              | {"endpoint": "post_todo_list_items"}
  8 | todo_list_items | 1  | 2024-07-07 17:14:01.446039 |      99 | {"title": "Buy milk"}  | {"title": "Buy milk and eggs"}                | {{user_id,42}}              | {"endpoint": "post_todo_list_items"}
  9 | todo_list_items | 1  | 2024-07-07 17:14:01.446712 |      99 | {"user_id": 42}        | {"user_id": 16}                               | {{user_id,42},{user_id,16}} | {"endpoint": "post_todo_list_items"}
```

# Implementation

`change_logs` is a partitioned tabled used stores the actual changes:

```sql
create table change_logs (
    id bigserial,

    -- Changed row's table and primary key
    tbl varchar(64) not null,
    pk varchar(256) not null,

    -- Change timestamp
    ts timestamp,

    -- ID of the user making the change, set by `change_logs_set_context`
    user_id int,

    -- Old and new values from the row
    old jsonb null,
    new jsonb null,

    -- It is often useful to ensure that certain columns - such as foreign keys
    -- to parent entities - are always logged and indexed to simplify querying.
    -- For example, if a `todo_list_item` has a `user_id` column, it could be
    -- useful to index this column so that all changes to a user's items can be
    -- easily queried.
    indexed text[][2] null,

    -- Context set by `change_logs_set_context`
    context jsonb null,

    primary key (id, ts)
) partition by range (ts);

create index if not exists change_logs_tbl_pk_idx on change_logs (tbl, pk);
create index if not exists change_logs_indexed_idx on change_logs using gin (indexed) where indexed is not null;
```

(by default `change_logs` is partitioned by month, but this can be changed by
modifying the `change_logs_partition_details_for_timestamp` function)

`change_logs_tracked_tables` is used to store the tables and columns to be tracked:

```sql
create table if not exists change_logs_tracked_tables (
    table_name varchar(64) primary key,
    pk_column varchar(64) not null,
    logged_columns text[] not null,
    indexed_columns text[] not null default '{}'
);
```

This table can be modified directly to change the columns which are logged and
indexed, or idempotent helper functions can be used:

```sql
select change_logs_add_logged_columns('todo_list_items', array['*', '-created_at', '-updated_at']);
select change_logs_add_indexed_columns('todo_list_items', array['user_id']);
```

Finally, the `change_logs_insert_update_delete_trigger` trigger function is used
to log changes, and the `after insert or update or delete` trigger calling it is
added to each tracked table by `change_logs_track_table`.

(the `change_logs_untrack_table` function can be used to remove the trigger)

# Caveats

* Composite primary keys are not supported. If necessary it would likely be
  possible to change the `pk` column from `pk varchar(256)` to `pk text[]`.
* Multiple schemas are not currently supported. This is not an inherent
  limitation, simply a lack of implementation. A pull request would be welcome!
* The core `change_logs` table and triggers have been used in multiple
  production applications for more than 5 years, so it is likely stable. The
  `indexed` column and automatic partitioning are newer, though, and should be
  reviewed with healthy of skepticism.


# Installation

## Pre-installation considerations

1. Storage: as a rough estimate from one production application, 10m
   `change_logs` rows consume about 10gb of storage.
2. Partition size: by default `change_logs` is partitioned by month
   (`change_logs_2406`, `change_logs_2407`, etc.). This can be changed by
   modifying the `change_logs_partition_details_for_timestamp` function.

## Installation


If changing the partition size is necessary, update the
`change_logs_partition_details_for_timestamp` function.

Load the `change_logs.sql` file:

```bash
psql < change_logs.sql
```

Finally, while not not strictly necessary, it's likely useful to track changes
to the `change_logs_tracked_tables` table:

```bash
psql <<< "select change_logs_track_table('change_logs_tracked_tables', 'table_name', array['*']);"
```

## Application Integration

Some application integration is required to set the `user_id` and `context` for
each change.

This will vary depending on the application, but a common pattern is to call
`change_logs_set_context` before any query which could modify the database.

A simplified example of how this can be done with Python and SQLAlchemy:

```python
def before_cursor_execute(conn, cursor, query, *a, **kw):
    if re.match(r'\b(insert|update|delete)\b', query, re.I):
        conn.execute("""
            select change_logs_set_context(
                _user_id => %s,
                _context_str => %s
            );
        """, [current_user.id, json.dumps({ 'endpoint': request.endpoint })])
```

See a complete example in [examples/sqlalchemy_flask.py](examples/sqlalchemy_flask.py).

Note: the change logs context is set for the duration of the *connection*,
not the transaction. This means that, if a connection is reused, the context
will be also be reused. While this is not perfect, it was deemed "less
undesirable" than the alternative, as it reduces the number of queries required
to maintain context, and it's likely "less bad" to accidentally leak context between
transactions than to accidentally lose context. If your application has different
requirements, the `change_logs_set_context` function can be modified accordingly.


# "Indexed" columns

It can be useful to query for all changes related to a certain entity, such as
all the children of a parent, but this is not straightforward with only the
`old` and `new` values.

The `indexed` column is used to unconditionally store the values of certain
columns, such as foreign keys to parent entities, and as the name suggests it is
indexed to make these queries efficient.

For example, to find all the changes made to a particular user's todo list
items, the following query can be used:

```sql
select * from change_logs where indexed @> array[array['user_id', '42']];
```

As with all indexes, some care should be taken to ensure that only necessary columns
are indexed, as this index has the potential to grow quite large.

(and to address an obvious question: the `indexed` column is `text[][2]` rather
than `hstore` or `jsonb` to handle situations where the value of an indexed
column changes)

# API Documentation

## `change_logs_track_table`

```sql
/*
change_logs_track_table: track changes to `_cols` on `_table`, with rows identified by
primary key column `_pk_col`. Optionally, unconditionally include the values of
`_indexed_cols`.

Note: if the table has previously been tracked with `change_logs_track_tables`, the
old `_pk_col` will be overwritten, and `_cols` will be added to the list of tracked columns.

For example::

    > select * from change_logs_track_table('users', 'id', array['username', 'email']);
    table_name | pk_column | logged_columns    | indexed_columns
    -----------+-----------+-------------------+----------------
    users      | id        | {username, email} | {}

    > select * from change_logs_track_table('users', 'unknown_column', array[...]);
    ERROR: Column "unknown_column" not found on table "users"

    > select * from change_logs_track_table('unknown_table', 'id', array[...]);
    ERROR: Table not found: "unknown_table"

The `_cols` array can contain the special value `*`, which will track all columns.

Columns in `_cols` prefixed with a '-' will not be tracked. These columns should
appear after the '*'.

For example::

    > select * from change_logs_track_table('users', 'id', array['*', '-password']);
    table_name | pk_column | logged_columns     | indexed_columns
    -----------+-----------+--------------------+----------------
    users      | id        | {'*', '-password'} | {}
*/
create function change_logs_track_table(_table text, _pk_col text, _cols text[], _indexed_cols text[] = null)
```

## `change_logs_untrack_table`

```sql
/*
change_logs_untrack_table: stop tracking changes to `_table`.

Drops the trigger on `_table` and removes the row from `change_logs_tracked_tables`.

It is safe to call this function multiple times on the same table.
*/
create function change_logs_untrack_table(_table text)
```

## `change_logs_add_logged_columns`

```sql
/*
change_logs_add_logged_columns: adds `_cols` to the list of columns tracked on `_table`.

Returns an error if `_table` is not tracked.

For example::

    > select * from change_logs_add_logged_columns('users', array['full_name']);
    table_name | pk_column | logged_columns
    -----------+-----------+----------------
    users      | id        | {username, email, full_name}

    > select * from change_logs_add_logged_columns('users', array['unknown_column']);
    ERROR: Column "unknown_column" not found on table "users"

    > select * from change_logs_add_logged_columns('unknown_table', array['email']);
    ERROR:  Table not found: "unknown_table"

The `_cols` array can contain the special value `*`, which will track all columns.

If any cols in `_cols` are prefixed with a '-', they will be removed from the
list of tracked columns. These columns should appear after the '*'.

For example::

    > select * from change_logs_add_logged_columns('users', array['*', '-password']);
    table_name | pk_column | logged_columns
    -----------+-----------+----------------
    users      | id        | {'*', '-password'}
*/
create function change_logs_add_logged_columns(_table text, _cols text[])
```

## `change_logs_add_indexed_columns`

```sql
/*
change_logs_add_indexed_columns: adds `_cols` to the list of columns indexed on `_table`.

Returns an error if `_table` is not tracked, or any of the columns in `_cols` are
invalid.

For example::

    > select * from change_logs_add_indexed_columns('users', array['full_name']);
    table_name | pk_column | index_columns
    -----------+-----------+----------------
    users      | id        | {full_name}

    > select * from change_logs_add_indexed_columns('users', array['unknown_column']);
    ERROR: Column "unknown_column" not found on table "users"

    > select * from change_logs_add_indexed_columns('unknown_table', array['email']);
    ERROR:  Table not found: "unknown_table"

*/
create function change_logs_add_indexed_columns(_table text, _cols text[])
```

## `change_logs_set_context`

```sql
/*
change_logs_set_context: sets the current user id to `_user_id` and `context` to
`_context` which will be included in any change logs incurred by the current
transaction.

Notes:
* Context is set for the duration of the current connection, *not* the current
  transaction (ie, `set_config(..., false)` is used).
* `_context_str` should be a JSON string (ex, `'{ "foo": "bar" }'`)

Example:

    > select change_logs_set_context(1, jsonb_build_object('rid', 'abc123');
*/
create function change_logs_set_context(_user_id int, _context_str text = null)
```

# Development + testing

Start the appropriate version of Postgres with:

    docker compose up -d pg14

Then run tests with:

    ./test 14 ./tests/test_simple.sql
    ./test 14 ./tests/test_partitioning.sql

And double check that the output looks correct.
