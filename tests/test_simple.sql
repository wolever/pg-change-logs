create table todo_list_items (
  id integer primary key,
  user_id integer,
  title text not null,
  created_at timestamp default now(),
  completed_at timestamp
);

select change_logs_track_table('todo_list_items', 'id', array['*', '-created_at'], array['user_id']);

insert into todo_list_items (id, user_id, title) values (1, 42, 'Buy milk');
update todo_list_items set title = 'Buy milk and eggs' where id = 1;

select change_logs_set_context(_user_id => 99, _context_str => '{"foo": "bar"}');
update todo_list_items set user_id = 16 where id = 1;
update todo_list_items set user_id = null where id = 1;
update todo_list_items set completed_at = now() where id = 1;

select change_logs_untrack_table('todo_list_items');
update todo_list_items set title = 'this should not be tracked';

select *
from change_logs
where tbl = 'todo_list_items'
order by id;
