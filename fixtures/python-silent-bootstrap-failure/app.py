from flask import Flask

import tracing

tracing.setup()

app = Flask(__name__)


@app.get("/quotes/<id>")
def get_quote(id):
    return {"id": id}
