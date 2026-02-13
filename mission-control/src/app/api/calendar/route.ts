import { NextResponse } from 'next/server';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { execSync } from 'child_process';

interface CronSchedule {
  kind: string;
  expr?: string;
  tz?: string;
  at?: string;
  everyMs?: number;
}

interface CronJob {
  id: string;
  name: string;
  description?: string;
  enabled: boolean;
  schedule: CronSchedule;
  state?: {
    nextRunAtMs?: number;
    lastRunAtMs?: number;
    lastStatus?: string;
    lastDurationMs?: number;
  };
}

// In-memory cache
let cachedData: { jobs: CronJob[]; ts: number } | null = null;
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

function loadJobs(): CronJob[] {
  // Check cache
  if (cachedData && Date.now() - cachedData.ts < CACHE_TTL) {
    return cachedData.jobs;
  }

  let jobs: CronJob[] = [];

  // Try live exec first
  try {
    const raw = execSync('openclaw cron list --json', { timeout: 10000, encoding: 'utf-8' });
    const parsed = JSON.parse(raw);
    jobs = parsed.jobs || parsed;
    cachedData = { jobs, ts: Date.now() };
    return jobs;
  } catch {
    // fall through to file
  }

  // Fallback to static file
  const dataPath = join(process.cwd(), 'data', 'cron-jobs.json');
  if (existsSync(dataPath)) {
    try {
      const raw = readFileSync(dataPath, 'utf-8');
      const parsed = JSON.parse(raw);
      jobs = parsed.jobs || parsed;
      cachedData = { jobs, ts: Date.now() };
    } catch {
      // ignore
    }
  }

  return jobs;
}

function parseCronExpr(expr: string): { minute: number; hour: number; dayOfMonth: string; month: string; dayOfWeek: number[] } | null {
  const parts = expr.trim().split(/\s+/);
  if (parts.length < 5) return null;

  const [min, hour, dom, month, dow] = parts;
  const minute = min === '*' ? 0 : parseInt(min);
  const h = (hour === '*' || hour.includes('*')) ? -1 : parseInt(hour);

  let days: number[];
  if (dow === '*') {
    days = [0, 1, 2, 3, 4, 5, 6];
  } else if (dow.includes('-')) {
    const [start, end] = dow.split('-').map(Number);
    days = [];
    for (let i = start; i <= end; i++) days.push(i);
  } else if (dow.includes(',')) {
    days = dow.split(',').map(Number);
  } else {
    days = [parseInt(dow)];
  }

  return { minute, hour: h, dayOfMonth: dom, month, dayOfWeek: days };
}

export async function GET() {
  const jobs = loadJobs();
  const enabledJobs = jobs.filter(j => j.enabled !== false);

  const now = new Date();
  const startOfWeek = new Date(now);
  const dayOffset = now.getDay() === 0 ? -6 : 1 - now.getDay();
  startOfWeek.setDate(now.getDate() + dayOffset);
  startOfWeek.setHours(0, 0, 0, 0);

  const weekEvents: { day: string; hour: number; minute: number; name: string; id: string; schedule: string; status: string; nextRun?: string; lastRun?: string; description?: string }[] = [];

  for (const job of enabledJobs) {
    if (job.schedule.kind === 'cron' && job.schedule.expr) {
      const parsed = parseCronExpr(job.schedule.expr);
      if (!parsed) continue;
      
      // Expand hour: -1 means every hour or */N pattern
      let hours: number[];
      if (parsed.hour === -1) {
        // Check for */N pattern
        const hourPart = job.schedule.expr.trim().split(/\s+/)[1];
        if (hourPart.startsWith('*/')) {
          const interval = parseInt(hourPart.split('/')[1]);
          hours = [];
          for (let h = 0; h < 24; h += interval) hours.push(h);
        } else {
          continue; // every hour — too noisy, skip
        }
      } else {
        hours = [parsed.hour];
      }

      for (let d = 0; d < 7; d++) {
        const date = new Date(startOfWeek);
        date.setDate(startOfWeek.getDate() + d);
        const jsDay = date.getDay();

        if (!parsed.dayOfWeek.includes(jsDay)) continue;

        if (parsed.dayOfMonth !== '*') {
          const doms = parsed.dayOfMonth.split(',').map((s: string) => parseInt(s));
          if (!doms.includes(date.getDate())) continue;
        }

        for (const hr of hours) {
        weekEvents.push({
          day: date.toISOString().split('T')[0],
          hour: hr,
          minute: parsed.minute,
          name: job.name,
          id: job.id,
          schedule: `${job.schedule.expr}${job.schedule.tz ? ' @ ' + job.schedule.tz : ''}`,
          status: job.state?.lastStatus || 'idle',
          nextRun: job.state?.nextRunAtMs ? new Date(job.state.nextRunAtMs).toISOString() : undefined,
          lastRun: job.state?.lastRunAtMs ? new Date(job.state.lastRunAtMs).toISOString() : undefined,
          description: job.description,
        });
        } // end hours loop
      }
    } else if (job.schedule.kind === 'at' && job.schedule.at) {
      const atDate = new Date(job.schedule.at);
      const endOfWeek = new Date(startOfWeek);
      endOfWeek.setDate(startOfWeek.getDate() + 7);

      if (atDate >= startOfWeek && atDate < endOfWeek) {
        weekEvents.push({
          day: atDate.toISOString().split('T')[0],
          hour: atDate.getHours(),
          minute: atDate.getMinutes(),
          name: job.name,
          id: job.id,
          schedule: `once @ ${atDate.toISOString()}`,
          status: job.state?.lastStatus || 'scheduled',
          description: job.description,
        });
      }
    }
  }

  weekEvents.sort((a, b) => a.day.localeCompare(b.day) || a.hour - b.hour || a.minute - b.minute);

  return NextResponse.json({
    jobs: enabledJobs.map(j => ({
      id: j.id,
      name: j.name,
      description: j.description,
      schedule: j.schedule,
      status: j.state?.lastStatus || 'idle',
      nextRun: j.state?.nextRunAtMs ? new Date(j.state.nextRunAtMs).toISOString() : null,
      lastRun: j.state?.lastRunAtMs ? new Date(j.state.lastRunAtMs).toISOString() : null,
    })),
    weekEvents,
    weekStart: startOfWeek.toISOString().split('T')[0],
  });
}
