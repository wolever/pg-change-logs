import re
import json
from weakref import WeakKeyDictionary

import flask
from sqlalchemy import event, create_engine

def get_change_logs_context():
    """ Any time an INSERT, UPDATE, or DELETE is executed, determine the current
        user ID and context to be included with any change logs that are created.

        Note: this is an an example placeholder. Customize it as needed for your
        application.
    """
    current_user_id = None
    change_context = {}

    if flask.has_request_context():
        current_user_id = xxx_get_current_user_id()
        change_context.update({
            "endpoint": flask.request.endpoint,
            "rid": xxx_get_request_id(),
        })

    if xxx_background_task_context():
        change_context.update({
            "task": xxx_get_task_name(),
            "tid": xxx_get_task_id(),
        })

    return (current_user_id, change_context)


_cxn_current_context = WeakKeyDictionary()
_insert_update_delete_re = re.compile(r"\b(insert|update|delete)\b", re.I)

def sqlalchemy_before_cursor_execute_set_change_logs_context(
    conn,
    cur,
    query,
    *args,
    **kwargs,
):
    """ Before any INSERT, UPDATE, or DELETE is executed, set the change logs context
        for the current connection.

        Note: ``change_logs_set_context`` persists across transactions, so it is only
        necessary to set or update once per connection, or when the context changes.
    """
    is_insert_or_update = _insert_update_delete_re.search(query) is not None
    if not is_insert_or_update:
        return

    user_id, change_context = get_change_logs_context()
    change_context_str = json.dumps(change_context)

    raw_conn = conn._dbapi_connection.connection
    if _cxn_current_context.get(raw_conn) == (user_id, change_context_str):
        return

    _cxn_current_context[raw_conn] = (user_id, change_context_str)

    conn.execute(
        "select change_logs_set_context(%s, %s)",
        [user_id, change_context_str],
    )

engine = create_engine('postgresql+psycopg2://...')
event.listen(engine, "before_cursor_execute", sqlalchemy_before_cursor_execute_set_change_logs_context)
