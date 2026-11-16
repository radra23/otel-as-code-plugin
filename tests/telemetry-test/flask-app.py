"""A Flask (WSGI) service for the /otel-test end-to-end test: one route, one function to enrich."""
from flask import Flask, jsonify
from opentelemetry.instrumentation.flask import FlaskInstrumentor

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

ITEMS = {1: "kettle", 2: "teapot"}


def find_item(item_id):
    return ITEMS.get(item_id)


@app.get("/items/<int:item_id>")
def get_item(item_id):
    name = find_item(item_id)
    if name is None:
        return jsonify(error="not found"), 404
    return jsonify(id=item_id, name=name)
