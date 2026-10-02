from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/orders/<order_id>")
def get_order(order_id):
    return jsonify({"id": order_id, "status": "open"})


def main():
    app.run(host="0.0.0.0", port=8080)
