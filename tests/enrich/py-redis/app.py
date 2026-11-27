"""A catalog service that caches its items in Redis: a GET on every request, and a SET when the
item is found but not cached yet. REDIS_URL picks the server; CACHE_PREFIX keeps one run's keys
apart from another's."""
import os

import redis
from fastapi import FastAPI, HTTPException

CATALOG = {1: "kettle", 2: "teapot"}
cache = redis.Redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"), decode_responses=True)
PREFIX = os.environ.get("CACHE_PREFIX", "catalog")

app = FastAPI()


def find_item(item_id: int):
    key = f"{PREFIX}:item:{item_id}"
    name = cache.get(key)
    if name is None and item_id in CATALOG:
        name = CATALOG[item_id]
        cache.set(key, name)
    return {"id": item_id, "name": name} if name else None


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int):
    item = find_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found")
    return item
