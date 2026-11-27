"""The catalog service of py-psycopg on psycopg2: one SELECT on every request. DATABASE_URL picks
the server; ITEMS_TABLE keeps one run's rows apart from another's. The table is created and filled
once, at start-up."""
import os

import psycopg2
from fastapi import FastAPI, HTTPException

CATALOG = {1: "kettle", 2: "teapot"}
URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres")
TABLE = os.environ.get("ITEMS_TABLE", "items")

app = FastAPI()


@app.on_event("startup")
def create_items():
    conn = psycopg2.connect(URL)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE TABLE IF NOT EXISTS {TABLE} (id integer PRIMARY KEY, name text NOT NULL)")
            cur.executemany(f"INSERT INTO {TABLE} (id, name) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                            list(CATALOG.items()))
    finally:
        conn.close()


def find_item(item_id: int):
    conn = psycopg2.connect(URL)
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT id, name FROM {TABLE} WHERE id = %s", (item_id,))
            row = cur.fetchone()
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
