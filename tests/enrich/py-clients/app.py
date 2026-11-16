"""A catalog service that reads SQLite through the standard library's sqlite3 module."""
import sqlite3

from fastapi import FastAPI, HTTPException

app = FastAPI()
DB_PATH = "file:catalog?mode=memory&cache=shared"
_keep_open = sqlite3.connect(DB_PATH, uri=True)
_keep_open.executescript(
    "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);"
    "INSERT INTO items VALUES (1, 'kettle'), (2, 'teapot');"
)


def find_item(item_id: int):
    conn = sqlite3.connect(DB_PATH, uri=True)
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT id, name FROM items WHERE id = ?", (item_id,))
        row = cursor.fetchone()
    finally:
        conn.close()
    return {"id": row[0], "name": row[1]} if row else None


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int):
    item = find_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found")
    return item
