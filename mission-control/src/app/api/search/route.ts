import { getDb } from '@/lib/db';
import { NextRequest, NextResponse } from 'next/server';

export async function GET(req: NextRequest) {
  const db = getDb();
  const q = req.nextUrl.searchParams.get('q');

  if (!q || q.trim().length === 0) {
    return NextResponse.json({ results: [] });
  }

  // Search FTS index
  const ftsResults = db.prepare(`
    SELECT source, path, title, snippet(search_index, 3, '<mark>', '</mark>', '...', 40) as snippet,
           rank
    FROM search_index
    WHERE search_index MATCH ?
    ORDER BY rank
    LIMIT 30
  `).all(q);

  // Also search activity
  const activityResults = db.prepare(`
    SELECT 'activity' as source, '' as path, 
           action_type || ': ' || description as title,
           description as snippet,
           timestamp
    FROM activity
    WHERE description LIKE ? OR action_type LIKE ?
    ORDER BY timestamp DESC
    LIMIT 20
  `).all(`%${q}%`, `%${q}%`);

  return NextResponse.json({
    results: [
      ...(ftsResults as Record<string, unknown>[]).map((r) => ({ ...r, type: 'file' })),
      ...(activityResults as Record<string, unknown>[]).map((r) => ({ ...r, type: 'activity' })),
    ],
  });
}
