/*
change_logs: use triggers to automatically track changes to certain columns in
database tables.

To enable change tracking for a table:

    select change_logs_track_table(
        _table => 'todo_list_items',
        _pk_col => 'id',
        _cols => array['*', '-created_at', '-updated_at'],
        _indexed_cols => array['user_id']
    );

This will do two things:

1. Setup a trigger after inserts, updates, and deletes on 'table_to_track'
   which calls '_change_logs_insert_change(...)' each time there is a change to the
   table.

2. Write a row to 'change_logs_track_table' with the table name, primary key
   column, and columns to log.

The 'change_logs_track_table(...)' is idempotent and can safely be called
multiple times with different columns to track.

Considerations:

* Only necessary columns should be tracked, as it will get expensive to log all
  changes to all columns.
*/

create table if not exists change_logs (
    id bigserial,
    tbl varchar(64) not null,
    pk varchar(256) not null,
    ts timestamp,
    user_id int,
    old jsonb null,
    new jsonb null,
    indexed text[][2] null,
    context jsonb null,
    primary key (id, ts)
) partition by range (ts);

create index if not exists change_logs_tbl_pk_idx on change_logs (tbl, pk);
create index if not exists change_logs_indexed_idx on change_logs using gin (indexed) where indexed is not null;

create table if not exists change_logs_tracked_tables (
    table_name varchar(64) primary key,
    pk_column varchar(64) not null,
    logged_columns text[] not null,
    indexed_columns text[] not null default '{}'
);

/*
change_logs_partition_for_timestamp: returns a triple of the details needed to
create a new partition for a given timestamp: the partition name, the start
timestamp, and the end timestamp.

By default partitions are created monthly, but this function can be overridden
to create partitions based on a different interval.

For example::

    > select change_logs_partition_for_timestamp(now());
    [2407, 2024-07-01 00:00:00, 2024-08-01 00:00:00]
*/
create or replace function change_logs_partition_details_for_timestamp(_ts timestamp)
returns text[] as $pgsql$
begin
    return array[
        to_char(_ts, 'YYMM'),
        date_trunc('month', _ts)::text,
        date_trunc('month', _ts + interval '1 month')::text
    ];
end;
$pgsql$ language plpgsql;

/*
(internal) selects `_cols` from `_obj`, returning a new object containing only
the columns in `_cols`.

`_cols` can contain a wildcard `*` to select all columns, and a column name
can be prefixed with '-' to exclude it from the result.
> _change_logs_join_columns(array['*', '-foo'], '{"foo": "bar", "baz": 42}')
{'baz': 42}
*/
create or replace function _change_logs_jsonb_filter_object(_cols text[], _obj jsonb)
returns jsonb as $pgsql$
declare
    res jsonb := jsonb_build_object();
    col text;
    cols_to_log text[];
begin
    if _obj is null then
        return null;
    end if;

    cols_to_log := case
        when '*' = any(_cols) then array(select jsonb_object_keys(_obj)) || _cols
        else _cols
    end;

    foreach col in array cols_to_log loop
        if col = '*' then
            continue;
        end if;
        res := case
            when col like '-%' then res - substring(col, 2)
            else res || jsonb_build_object(col, _obj->col)
        end;
    end loop;
    return res;
end;
$pgsql$ language plpgsql returns null on null input;

/*
(internal) _change_logs_insert_change: creates a record in the `change_logs` table.

Called by `change_logs_insert_update_delete_trigger` each time a row is inserted,
updated, or deleted in a table which is tracked by `change_logs_track_table`.
*/
create or replace function _change_logs_insert_change(_ts timestamp, _table text, _old_orig jsonb, _new_orig jsonb)
returns void as $pgsql$
declare
    def change_logs_tracked_tables;
    _pk text;
    col text;
    old_to_add jsonb;
    new_to_add jsonb;
    did_change boolean;
    _old jsonb := _old_orig;
    _new jsonb := _new_orig;
    _indexed text[][2];
begin
    def := (
        select row(t.*)
        from change_logs_tracked_tables as t
        where table_name = _table
    );
    if def is null then
        return;
    end if;

    _pk := COALESCE(_new->>(def.pk_column), _old->>(def.pk_column));
    if _pk is null THEN
        raise exception 'Primary key % for table % not found in old=% or new=%', def.pk_column, _table, _old, _new;
    end if;

    -- Build the new and old objects, filtering out columns that are not logged
    _old := _change_logs_jsonb_filter_object(def.logged_columns, _old);
    _new := _change_logs_jsonb_filter_object(def.logged_columns, _new);

    -- Build the indexed columns
    if def.indexed_columns is not null then
        _indexed := array(
            select array[c, _new_orig->>c]
            from unnest(def.indexed_columns) as c
            where _new_orig is not null

            union

            select array[c, _old_orig->>c]
            from unnest(def.indexed_columns) as c
            where _old_orig is not null
        );
        if array_length(_indexed, 1) is null then
            _indexed := null;
        end if;
    end if;

    -- Handle new rows
    if _old is null then
        insert into change_logs (
            tbl, pk,
            ts,
            user_id,
            old, new,
            indexed,
            context
        ) values (
            _table, _pk,
            _ts,
            nullif(current_setting('change_logs.current_user_id', true), '')::integer,
            null, _new,
            _indexed,
            nullif(current_setting('change_logs.current_context', true), '')::jsonb
        );
        return;
    end if;

    -- Handle changes to existing rows
    if _new is not null then
        old_to_add := jsonb_build_object();
        new_to_add := jsonb_build_object();

        did_change := false;
        foreach col in array array(select jsonb_object_keys(_old)) loop
            if (_old->col) is distinct from (_new->col) then
                did_change := true;
                old_to_add := old_to_add || jsonb_build_object(col, _old->col);
                new_to_add := new_to_add || jsonb_build_object(col, _new->col);
            end if;
        end loop;

        if not did_change then
            return;
        end if;

        insert into change_logs (
            tbl, pk,
            ts,
            user_id,
            old, new,
            indexed,
            context
        ) values (
            _table, _pk,
            _ts,
            nullif(current_setting('change_logs.current_user_id', true), '')::integer,
            old_to_add, new_to_add,
            _indexed,
            nullif(current_setting('change_logs.current_context', true), '')::jsonb
        );
        return;
    end if;

    -- Handle deleted rows
    if _new is null then
        insert into change_logs (
            tbl, pk,
            ts,
            user_id,
            old, new,
            indexed,
            context
        ) values (
            _table, _pk,
            _ts,
            nullif(current_setting('change_logs.current_user_id', true), '')::integer,
            _old, null,
            _indexed,
            nullif(current_setting('change_logs.current_context', true), '')::jsonb
        );
        return;
    end if;
exception when others then
    -- This is either a unique constraint violation or a 'no partition of relation'
    -- error. If it's a 'no partition of relation' error, create the partition
    -- and try again, otherwise, raise the error.
    if not (sqlerrm like '%no partition of relation "change_logs"%') then
        raise;
    end if;

    declare
        _pt_details text[] := change_logs_partition_details_for_timestamp(_ts);
        _new_tbl text := 'change_logs_' || _pt_details[1];
    begin
        raise notice 'Creating new change_logs partition: %', _new_tbl;
        execute
            'CREATE TABLE IF NOT EXISTS ' || _new_tbl || ' ' ||
            '(LIKE change_logs INCLUDING ALL);';

        execute
            'ALTER TABLE change_logs ' ||
            'ATTACH PARTITION ' || _new_tbl || ' ' ||
            'FOR VALUES ' ||
            '  FROM (' || quote_literal(_pt_details[2]) || '::timestamp) ' ||
            '  TO (' || quote_literal(_pt_details[3]) || '::timestamp)';

        perform _change_logs_insert_change(_ts, _table, _old_orig, _new_orig);
    end;
end;
$pgsql$ language plpgsql;

/*
(internal) change_logs_insert_update_delete_trigger: trigger added to all
tables tracked with `change_logs_track_table`.
*/
create or replace function change_logs_insert_update_delete_trigger()
returns trigger as $pgsql$
begin
    perform _change_logs_insert_change(
        now() at time zone 'utc',
        TG_TABLE_NAME::text,
        case TG_OP when 'INSERT' then NULL else row_to_json(OLD)::jsonb end,
        case TG_OP when 'DELETE' then NULL else row_to_json(NEW)::jsonb end
    );
    return new;
end;
$pgsql$ language plpgsql;

/*
(internal) _change_logs_assert_column: asserts that `_col` exists on `_table`.

When `_col='*'`, this function asserts only that `_table` exists.

When `_col like '-%'`, this function will strip the '-' before asserting that
`_col` exists on `_table`.
*/
drop function if exists _change_logs_assert_column(text, text);
create or replace function _change_logs_assert_column(
    _table text,
    _col text,
    _literal_only boolean default false
)
returns void as $pgsql$
declare
    cols text[];
begin
    if _col = '*' and not _literal_only then
        return;
    end if;

    if _col like '-%' and not _literal_only then
        _col := substring(_col, 2);
    end if;

    cols := (
      SELECT array_agg(column_name)
      FROM information_schema.columns
      WHERE table_name=_table
    );

    if cols is null then
        raise exception 'Table not found: "%"', _table;
    end if;

    if not (_col = any(cols)) then
        raise exception 'Column "%" not found on table "%"', _col, _table;
    end if;
end;
$pgsql$ language plpgsql;

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
create or replace function change_logs_track_table(_table text, _pk_col text, _cols text[], _indexed_cols text[] = null)
returns change_logs_tracked_tables as $pgsql$
begin
    perform _change_logs_assert_column(_table, _pk_col);

    execute 'drop trigger if exists ' || quote_ident(_table || '_change_logs_tracker') || ' ' ||
        'on ' || quote_ident(_table);
    execute 'create trigger ' || quote_ident(_table || '_change_logs_tracker') || ' ' ||
        'after insert or update or delete ' ||
        'on ' || quote_ident(_table) || ' ' ||
        'for each row execute procedure change_logs_insert_update_delete_trigger()';
    insert into change_logs_tracked_tables (table_name, pk_column, logged_columns)
    values (_table, _pk_col, '{}'::text[])
    on conflict (table_name) do update
    set
        pk_column = _pk_col;

    perform change_logs_add_indexed_columns(_table, _indexed_cols);
    return change_logs_add_logged_columns(_table, _cols);
end;
$pgsql$ language plpgsql;

/*
change_logs_untrack_table: stop tracking changes to `_table`.

Drops the trigger on `_table` and removes the row from `change_logs_tracked_tables`.

It is safe to call this function multiple times on the same table.
*/
create or replace function change_logs_untrack_table(_table text)
returns change_logs_tracked_tables as $pgsql$
declare
    res change_logs_tracked_tables;
begin
    execute 'drop trigger if exists ' || quote_ident(_table || '_change_logs_tracker') || ' ' ||
        'on ' || quote_ident(_table);

    delete from change_logs_tracked_tables
    where table_name = _table
    returning * into res;
    return res;
end;
$pgsql$ language plpgsql;

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
create or replace function change_logs_add_logged_columns(_table text, _cols text[])
returns change_logs_tracked_tables as $pgsql$
declare
  res record;
  _col text;
begin
    foreach _col in array _cols loop
       perform _change_logs_assert_column(_table, _col);
    end loop;

    update change_logs_tracked_tables
    set logged_columns = logged_columns || (select array(
        select col
        from unnest(_cols) as x(col)
        where not (col = any(logged_columns))
    ))
    where table_name = _table
    returning * into res;

    if res is null then
        raise exception 'Table "%" not logged (hint: use `change_logs_track_table("%", ''%''::text[])`', _table, _table, _cols;
    end if;

    return res;
end;
$pgsql$ language plpgsql;

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
create or replace function change_logs_add_indexed_columns(_table text, _cols text[])
returns change_logs_tracked_tables as $pgsql$
declare
  res record;
  _col text;
  _new_cols text[];
begin
    foreach _col in array coalesce(_cols, '{}'::text[]) loop
       perform _change_logs_assert_column(_table, _col, true);
    end loop;

    _new_cols := array(
        select unnest(indexed_columns) as col
        from change_logs_tracked_tables
        where table_name = _table

        union

        select col
        from unnest(_cols) as x(col)
    );

    update change_logs_tracked_tables
    set indexed_columns = _new_cols
    where table_name = _table
    returning * into res;

    if res is null then
        raise exception 'Table "%" not logged (hint: use `change_logs_track_table("%", ''%''::text[])`', _table, _table, _cols;
    end if;

    return res;
end;
$pgsql$ language plpgsql;

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
create or replace function change_logs_set_context(_user_id int, _context_str text = null)
returns void as $pgsql$
begin
    begin
        perform (select _context_str::jsonb);
    exception when others then
        raise exception 'change_logs_set_context: _context_str is not valid JSON: % (%)', quote_literal(_context_str), sqlerrm;
    end;
    perform set_config('change_logs.current_user_id', _user_id::text, false);
    perform set_config('change_logs.current_context', _context_str, false);
end;
$pgsql$ language plpgsql;
