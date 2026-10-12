"""Commit one update to a real SQLite WAL, then skip connection shutdown.

The Swift recovery test invokes this in a child process. os._exit models an
abrupt process end without sqlite3_close/checkpoint, not an in-transaction kill.
"""

import os
import sqlite3
import sys


connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("PRAGMA wal_autocheckpoint=0")
cursor = connection.execute(
    "UPDATE messages SET title = ? WHERE message_id = ?", (sys.argv[3], sys.argv[2])
)
if cursor.rowcount != 1:
    raise RuntimeError(f"expected exactly one message, updated {cursor.rowcount}")
connection.commit()
os._exit(0)
