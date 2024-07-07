-- partition by millisecond
create or replace function change_logs_partition_details_for_timestamp(_ts timestamp)
returns text[] as $pgsql$
begin
    return array[
        to_char(_ts, 'YYYY_MM_DD_HH_MI_SS_MS'),
        _ts::text,
        (_ts + interval '1 millisecond')::text
    ];
end;
$pgsql$ language plpgsql;

create table ms_test (
  id integer primary key,
  val text
);

select change_logs_track_table('ms_test', 'id', array['*']);

insert into ms_test values (1, 'a');
insert into ms_test values (2, 'b');
insert into ms_test values (3, 'c');
insert into ms_test values (4, 'd');
insert into ms_test values (5, 'e');

select * from change_logs order by id;

\dt
