from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="inventory-api", version="0.3.1")


class StockUpdate(BaseModel):
    sku: str
    quantity: int
    warehouse: str


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/inventory/{sku}")
def get_stock(sku: str):
    # Simulate stock lookup
    return {"sku": sku, "quantity": 42, "warehouse": "us-east-1"}


@app.post("/inventory/reserve")
def reserve_stock(update: StockUpdate):
    if update.quantity <= 0:
        raise HTTPException(status_code=400, detail="quantity must be positive")
    return {"reserved": True, "sku": update.sku, "quantity": update.quantity}
