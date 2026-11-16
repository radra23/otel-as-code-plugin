'use strict';
// The catalog lives in SQLite through Node's built-in client, which no OpenTelemetry
// instrumentation package covers. `pg` is in package.json to show the other case: the bundle the
// bootstrap loads already covers it.
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync(':memory:');
db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items VALUES (1, 'kettle'), (2, 'teapot');");

function findItem(id) {
  const row = db.prepare('SELECT id, name FROM items WHERE id = ?').get(id);
  return row ? { id: row.id, name: row.name } : null;
}

module.exports = { findItem };
