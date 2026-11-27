"""The catalog service of py-psycopg on asyncio: asyncpg, async routes, one SELECT on every
request. DATABASE_URL picks the server; ITEMS_TABLE keeps one run's rows apart from another's. The
table is created and filled once, at start-up."""
import os

import asyncpg
from fastapi import FastAPI, HTTPException

CATALOG = {1: "kettle", 2: "teapot"}
URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/postgres")
TABLE = os.environ.get("ITEMS_TABLE", "items")

app = FastAPI()


@app.on_event("startup")
async def create_items():
    conn = await asyncpg.connect(URL)
    try:
        await conn.execute(f"CREATE TABLE IF NOT EXISTS {TABLE} (id integer PRIMARY KEY, name text NOT NULL)")
        await conn.executemany(f"INSERT INTO {TABLE} (id, name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                               list(CATALOG.items()))
    finally:
        await conn.close()


async def find_item(item_id: int):
    conn = await asyncpg.connect(URL)
    try:
        row = await conn.fetchrow(f"SELECT id, name FROM {TABLE} WHERE id = $1", item_id)
    finally:
        await conn.close()
    return {"id": row["id"], "name": row["name"]} if row else None


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
async def get_item(item_id: int):
    item = await find_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found")
    return item
