import Database from 'better-sqlite3';
import path from 'path';

const DB_PATH = path.join(process.cwd(), 'data', 'mission-control.db');

let db: Database.Database | null = null;

export function getDb(): Database.Database {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    migrate(db);
  }
  return db;
}

function migrate(db: Database.Database) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS activity (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      action_type TEXT NOT NULL,
      description TEXT NOT NULL,
      details TEXT DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'success',
      duration_ms INTEGER DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_activity_timestamp ON activity(timestamp DESC);
    CREATE INDEX IF NOT EXISTS idx_activity_type ON activity(action_type);

    CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
      source,
      path,
      title,
      content,
      tokenize='porter unicode61'
    );
  `);
}
