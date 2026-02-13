"use client";

import { useEffect, useState } from "react";

interface WeekEvent {
  day: string;
  hour: number;
  minute: number;
  name: string;
  schedule: string;
  status: string;
  description?: string;
}

interface CronJob {
  name: string;
  description?: string;
  schedule: { kind: string; expr?: string; tz?: string; at?: string } | string;
  status?: string;
  nextRun?: string | null;
  lastRun?: string | null;
}

const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function statusStyle(status: string): { bg: string; color: string } {
  switch (status) {
    case "ok":
    case "success":
      return { bg: "rgba(34,197,94,0.2)", color: "var(--success)" };
    case "error":
    case "fail":
      return { bg: "rgba(239,68,68,0.2)", color: "var(--error)" };
    case "idle":
    case "scheduled":
      return { bg: "rgba(245,158,11,0.15)", color: "var(--warning)" };
    default:
      return { bg: "var(--accent)", color: "#fff" };
  }
}

export default function CalendarView() {
  const [events, setEvents] = useState<WeekEvent[]>([]);
  const [jobs, setJobs] = useState<CronJob[]>([]);
  const [weekStart, setWeekStart] = useState("");

  useEffect(() => {
    fetch("/api/calendar")
      .then((r) => r.json())
      .then((data) => {
        setEvents(data.weekEvents || []);
        setJobs(data.jobs || []);
        setWeekStart(data.weekStart || "");
      });
  }, []);

  const getDayDate = (dayIdx: number) => {
    if (!weekStart) return "";
    const d = new Date(weekStart);
    d.setDate(d.getDate() + dayIdx);
    return d.toISOString().split("T")[0];
  };

  const getEventsAt = (dayIdx: number, hour: number) => {
    const date = getDayDate(dayIdx);
    return events.filter((e) => e.day === date && e.hour === hour);
  };

  // Count events per day
  const dayEventCount = (dayIdx: number) => {
    const date = getDayDate(dayIdx);
    return events.filter((e) => e.day === date).length;
  };

  // Only hours that have events
  const activeHours = [...new Set(events.map((e) => e.hour))].sort((a, b) => a - b);

  return (
    <div>
      <div className="mb-3">
        <h2 className="text-lg font-bold">Calendar</h2>
        <p className="text-xs" style={{ color: "var(--text-secondary)" }}>
          Week of {weekStart || "..."} · {jobs.length} jobs · {events.length} events
        </p>
      </div>

      {/* Weekly grid - only active hours */}
      {activeHours.length > 0 && (
        <div className="overflow-auto rounded-lg mb-4" style={{ background: "var(--bg-card)" }}>
          <div className="min-w-[700px]">
            <div className="grid grid-cols-[50px_repeat(7,1fr)] border-b" style={{ borderColor: "var(--border)" }}>
              <div className="p-1.5 text-[10px]" style={{ color: "var(--text-secondary)" }}></div>
              {DAYS.map((day, i) => {
                const count = dayEventCount(i);
                return (
                  <div key={day} className="p-1.5 text-center text-xs font-medium" style={{ borderLeft: "1px solid var(--border)" }}>
                    {day} <span className="text-[10px]" style={{ color: "var(--text-secondary)" }}>{getDayDate(i).slice(5)}</span>
                    {count > 0 && (
                      <span className="ml-1 text-[9px] px-1 py-0 rounded-full" style={{ background: "var(--accent)", color: "#fff" }}>
                        {count}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>

            {activeHours.map((hour) => (
              <div key={hour} className="grid grid-cols-[50px_repeat(7,1fr)]" style={{ borderBottom: "1px solid var(--border)" }}>
                <div className="p-1 text-[10px] text-right pr-2" style={{ color: "var(--text-secondary)" }}>
                  {hour.toString().padStart(2, "0")}:00
                </div>
                {DAYS.map((_, dayIdx) => {
                  const evts = getEventsAt(dayIdx, hour);
                  return (
                    <div key={dayIdx} className="min-h-[26px] p-0.5" style={{ borderLeft: "1px solid var(--border)" }}>
                      {evts.map((e, ei) => {
                        const s = statusStyle(e.status);
                        return (
                          <div
                            key={ei}
                            className="text-[9px] px-1 py-0.5 rounded truncate mb-0.5"
                            style={{ background: s.bg, color: s.color }}
                            title={`${e.name}\n${e.schedule}\nStatus: ${e.status}${e.description ? '\n' + e.description : ''}`}
                          >
                            {e.name}
                          </div>
                        );
                      })}
                    </div>
                  );
                })}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Job summary panel */}
      {jobs.length > 0 && (
        <div>
          <h3 className="text-sm font-semibold mb-2">Job Summary</h3>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
            {jobs.map((job, i) => {
              const s = statusStyle(job.status || "idle");
              return (
                <div key={i} className="p-2.5 rounded-lg" style={{ background: "var(--bg-card)" }}>
                  <div className="text-sm font-medium flex items-center gap-1.5">
                    <span className="text-[10px] w-2 h-2 rounded-full inline-block" style={{ background: s.color }}></span>
                    {job.name}
                  </div>
                  <div className="text-[10px] mt-0.5 font-mono" style={{ color: "var(--text-secondary)" }}>
                    {typeof job.schedule === "string" ? job.schedule : job.schedule.expr ? `${job.schedule.expr}${job.schedule.tz ? " @ " + job.schedule.tz : ""}` : job.schedule.kind}
                  </div>
                  <div className="flex gap-3 mt-1 text-[10px]" style={{ color: "var(--text-secondary)" }}>
                    {job.nextRun && <span>Next: {new Date(job.nextRun).toLocaleString()}</span>}
                    <span className="px-1.5 py-0 rounded-full" style={{ background: s.bg, color: s.color }}>{job.status || "idle"}</span>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {events.length === 0 && jobs.length === 0 && (
        <div className="text-center py-12" style={{ color: "var(--text-secondary)" }}>
          <p className="text-3xl mb-2">📅</p>
          <p className="text-sm">No cron jobs found</p>
        </div>
      )}
    </div>
  );
}
