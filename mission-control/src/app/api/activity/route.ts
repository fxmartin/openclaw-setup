import { getDb } from '@/lib/db';
import { NextRequest, NextResponse } from 'next/server';

export async function GET(req: NextRequest) {
  const db = getDb();
  const url = req.nextUrl;
  const type = url.searchParams.get('type');
  const limit = parseInt(url.searchParams.get('limit') || '50');
  const offset = parseInt(url.searchParams.get('offset') || '0');

  let query = 'SELECT * FROM activity';
  const params: (string | number)[] = [];

  if (type) {
    query += ' WHERE action_type = ?';
    params.push(type);
  }

  query += ' ORDER BY timestamp DESC LIMIT ? OFFSET ?';
  params.push(limit, offset);

  const rows = db.prepare(query).all(...params);
  const total = db.prepare(
    type
      ? 'SELECT COUNT(*) as count FROM activity WHERE action_type = ?'
      : 'SELECT COUNT(*) as count FROM activity'
  ).get(...(type ? [type] : [])) as { count: number };

  // Today's count
  const todayCount = db.prepare(
    "SELECT COUNT(*) as count FROM activity WHERE timestamp >= date('now', 'start of day')"
  ).get() as { count: number };

  return NextResponse.json({ entries: rows, total: total.count, todayCount: todayCount.count });
}

export async function POST(req: NextRequest) {
  const db = getDb();
  const body = await req.json();
  const { action_type, description, details, status, duration_ms } = body;

  if (!action_type || !description) {
    return NextResponse.json({ error: 'action_type and description required' }, { status: 400 });
  }

  const stmt = db.prepare(`
    INSERT INTO activity (action_type, description, details, status, duration_ms)
    VALUES (?, ?, ?, ?, ?)
  `);

  const result = stmt.run(
    action_type,
    description,
    JSON.stringify(details || {}),
    status || 'success',
    duration_ms || 0
  );

  return NextResponse.json({ id: result.lastInsertRowid }, { status: 201 });
}

export async function DELETE() {
  const db = getDb();
  db.prepare('DELETE FROM activity').run();
  return NextResponse.json({ ok: true });
}
