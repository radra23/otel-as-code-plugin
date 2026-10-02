from flask import Blueprint, jsonify

bp = Blueprint("orders", __name__)


@bp.get("/orders/<int:order_id>")
def order_detail(order_id):
    return jsonify({"id": order_id, "status": "open"})


@bp.get("/healthz")
def healthz():
    return jsonify({"ok": True})
