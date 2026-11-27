"""The catalog service of py-pymysql on mysql-connector-python, Oracle's driver (its C extension by
default): one SELECT on every request.
MYSQL_HOST, MYSQL_PASSWORD and MYSQL_DATABASE pick the server; ITEMS_TABLE keeps one run's rows
apart from another's. The table is created and filled once, at start-up."""
import os

import mysql.connector
from fastapi import FastAPI, HTTPException

CATALOG = {1: "kettle", 2: "teapot"}
TABLE = os.environ.get("ITEMS_TABLE", "items")

app = FastAPI()


def connect():
    return mysql.connector.connect(host=os.environ.get("MYSQL_HOST", "127.0.0.1"), user="root",
                           password=os.environ.get("MYSQL_PASSWORD", "mysql"),
                           database=os.environ.get("MYSQL_DATABASE", "catalog"), autocommit=True)


@app.on_event("startup")
def create_items():
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE TABLE IF NOT EXISTS {TABLE} (id integer PRIMARY KEY, name text NOT NULL)")
            cur.executemany(f"INSERT IGNORE INTO {TABLE} (id, name) VALUES (%s, %s)", list(CATALOG.items()))
    finally:
        conn.close()


def find_item(item_id: int):
    conn = connect()
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
