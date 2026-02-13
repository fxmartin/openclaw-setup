import { getDb } from '@/lib/db';
import { NextResponse } from 'next/server';
import fs from 'fs';
import path from 'path';

function walkMdFiles(dir: string, files: string[] = []): string[] {
  if (!fs.existsSync(dir)) return files;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules') {
      walkMdFiles(full, files);
    } else if (entry.isFile() && /\.(md|txt)$/i.test(entry.name)) {
      files.push(full);
    }
  }
  return files;
}

export async function POST() {
  const db = getDb();
  const workspace = '/home/fx/clawd';

  // Clear existing file entries
  db.exec("DELETE FROM search_index WHERE source = 'file'");

  const insert = db.prepare(
    'INSERT INTO search_index (source, path, title, content) VALUES (?, ?, ?, ?)'
  );

  const files = walkMdFiles(workspace);
  let indexed = 0;

  const tx = db.transaction(() => {
    for (const file of files) {
      try {
        const content = fs.readFileSync(file, 'utf-8');
        if (content.length > 0 && content.length < 500000) {
          const relPath = path.relative(workspace, file);
          insert.run('file', relPath, path.basename(file), content);
          indexed++;
        }
      } catch { /* skip unreadable */ }
    }
  });

  tx();

  // Also index activity entries
  db.exec("DELETE FROM search_index WHERE source = 'activity'");
  db.exec(`
    INSERT INTO search_index (source, path, title, content)
    SELECT 'activity', '', action_type || ': ' || description, 
           description || ' ' || COALESCE(details, '')
    FROM activity
  `);

  return NextResponse.json({ indexed, files: files.length });
}
