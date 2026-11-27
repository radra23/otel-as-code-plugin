"""The catalog service on Tortoise ORM over a SQLite file: one SELECT on every request. ITEMS_DB
picks the file. Tortoise creates the table and the catalog is written once, at start-up, inside
RegisterTortoise (Tortoise 1.x keeps its connections per context, so a bare Tortoise.init() in a
start-up handler is not seen by the requests)."""
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from tortoise import fields
from tortoise.contrib.fastapi import RegisterTortoise
from tortoise.models import Model

CATALOG = {1: "kettle", 2: "teapot"}
DB = os.environ.get("ITEMS_DB", "catalog.db")


class Item(Model):
    id = fields.IntField(primary_key=True)
    name = fields.TextField()


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with RegisterTortoise(app, db_url=f"sqlite://{DB}", modules={"models": ["app"]}, generate_schemas=True):
        await Item.bulk_create([Item(id=i, name=n) for i, n in CATALOG.items()])
        yield


app = FastAPI(lifespan=lifespan)


async def find_item(item_id: int):
    item = await Item.get_or_none(id=item_id)
    return {"id": item.id, "name": item.name} if item else None


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
async def get_item(item_id: int):
    item = await find_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found")
    return item
