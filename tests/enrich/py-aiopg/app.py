"""The catalog service of py-psycopg on aiopg, which runs psycopg2 connections in async mode: one
SELECT on every request. DATABASE_URL picks the server; ITEMS_TABLE keeps one run's rows apart
from another's. The table is created and filled once, at start-up (aiopg has no executemany)."""
import os

import aiopg
from fastapi import FastAPI, HTTPException

CATALOG = {1: "kettle", 2: "teapot"}
URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres")
TABLE = os.environ.get("ITEMS_TABLE", "items")

app = FastAPI()


@app.on_event("startup")
async def create_items():
    async with aiopg.connect(URL) as conn:
        async with conn.cursor() as cur:
            await cur.execute(f"CREATE TABLE IF NOT EXISTS {TABLE} (id integer PRIMARY KEY, name text NOT NULL)")
            for item_id, name in CATALOG.items():
                await cur.execute(f"INSERT INTO {TABLE} (id, name) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                                  (item_id, name))


async def find_item(item_id: int):
    async with aiopg.connect(URL) as conn:
        async with conn.cursor() as cur:
            await cur.execute(f"SELECT id, name FROM {TABLE} WHERE id = %s", (item_id,))
            row = await cur.fetchone()
    return {"id": row[0], "name": row[1]} if row else None


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
async def get_item(item_id: int):
    item = await find_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found")
    return item
