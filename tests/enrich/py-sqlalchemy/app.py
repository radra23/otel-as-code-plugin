"""A catalog service that reads SQLite through SQLAlchemy. The engine opens its connections with
the standard library's sqlite3 module, so the service uses both: SQLAlchemy is the one to
instrument, and sqlite3 sits under it."""
import sqlite3

from fastapi import FastAPI, HTTPException
from sqlalchemy import create_engine, text
from sqlalchemy.pool import StaticPool

DB_PATH = "file:catalog?mode=memory&cache=shared"
engine = create_engine("sqlite://", creator=lambda: sqlite3.connect(DB_PATH, uri=True, check_same_thread=False),
                       poolclass=StaticPool)
with engine.begin() as conn:
    conn.execute(text("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)"))
    conn.execute(text("INSERT INTO items VALUES (1, 'kettle'), (2, 'teapot')"))

app = FastAPI()


def find_item(item_id: int):
    with engine.connect() as conn:
        row = conn.execute(text("SELECT id, name FROM items WHERE id = :id"), {"id": item_id}).first()
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
