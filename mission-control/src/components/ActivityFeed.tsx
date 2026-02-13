"use client";

import { useEffect, useState, useCallback } from "react";

interface Activity {
  id: number;
  timestamp: string;
  action_type: string;
  description: string;
  details: string;
  status: string;
  duration_ms: number;
}

const ACTION_ICONS: Record<string, string> = {
  tool_call: "🔧",
  email: "📧",
  web_search: "🌐",
  cron: "⏰",
  file_op: "📁",
  message: "💬",
  api_call: "🔌",
  error: "❌",
  system: "⚙️",
};

const ACTION_TYPES = ["all", "tool_call", "email", "web_search", "cron", "file_op", "message", "api_call", "system"];

function relTime(ts: string): string {
  const diff = Date.now() - new Date(ts).getTime();
  if (diff < 0) return "just now";
  if (diff < 60000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
  return `${Math.floor(diff / 86400000)}d ago`;
}

function fmtDuration(ms: number): string {
  if (ms === 0) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function statusColor(status: string): { bg: string; color: string } {
  switch (status) {
    case "success": return { bg: "rgba(34,197,94,0.15)", color: "var(--success)" };
    case "error": return { bg: "rgba(239,68,68,0.15)", color: "var(--error)" };
    case "warning": return { bg: "rgba(245,158,11,0.15)", color: "var(--warning)" };
    default: return { bg: "rgba(136,136,168,0.15)", color: "var(--text-secondary)" };
  }
}

export default function ActivityFeed() {
  const [entries, setEntries] = useState<Activity[]>([]);
  const [filter, setFilter] = useState("all");
  const [total, setTotal] = useState(0);

  const fetchData = useCallback(async () => {
    const params = new URLSearchParams();
    if (filter !== "all") params.set("type", filter);
    params.set("limit", "100");
    const res = await fetch(`/api/activity?${params}`);
    const data = await res.json();
    setEntries(data.entries);
    setTotal(data.total);
  }, [filter]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 5000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const clearAll = async () => {
    if (!confirm("Clear all activity entries?")) return;
    await fetch("/api/activity", { method: "DELETE" });
    fetchData();
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div>
          <h2 className="text-lg font-bold">Activity Feed</h2>
          <p className="text-xs" style={{ color: "var(--text-secondary)" }}>
            {total} entries · auto-refresh 5s
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button onClick={clearAll} className="text-xs px-2 py-1 rounded opacity-50 hover:opacity-100" style={{ color: "var(--error)" }}>
            Clear all
          </button>
        </div>
      </div>

      <div className="flex gap-1 flex-wrap mb-3">
        {ACTION_TYPES.map((t) => (
          <button
            key={t}
            onClick={() => setFilter(t)}
            className="px-2 py-1 rounded-full text-[10px] font-medium transition-colors"
            style={{
              background: filter === t ? "var(--accent)" : "var(--bg-card)",
              color: filter === t ? "#fff" : "var(--text-secondary)",
            }}
          >
            {t === "all" ? "All" : `${ACTION_ICONS[t] || "📋"} ${t}`}
          </button>
        ))}
      </div>

      <div className="space-y-1">
        {entries.length === 0 && (
          <div className="text-center py-12 rounded-lg" style={{ background: "var(--bg-card)", color: "var(--text-secondary)" }}>
            <p className="text-3xl mb-2">📭</p>
            <p className="text-sm">No activity entries yet</p>
          </div>
        )}
        {entries.map((e) => {
          const sc = statusColor(e.status);
          return (
            <div
              key={e.id}
              className="flex items-center gap-3 px-3 py-2 rounded-lg"
              style={{ background: "var(--bg-card)" }}
            >
              <span className="text-base shrink-0">{ACTION_ICONS[e.action_type] || "📋"}</span>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-sm font-medium truncate">{e.description}</span>
                  <span
                    className="text-[10px] px-1.5 py-0.5 rounded-full shrink-0"
                    style={{ background: sc.bg, color: sc.color }}
                  >
                    {e.status}
                  </span>
                </div>
                <div className="flex gap-3 mt-0.5 text-[10px]" style={{ color: "var(--text-secondary)" }}>
                  <span title={e.timestamp}>{relTime(e.timestamp)}</span>
                  <span className="px-1.5 py-0 rounded" style={{ background: "var(--bg-hover)" }}>{e.action_type}</span>
                  {e.duration_ms > 0 && <span>{fmtDuration(e.duration_ms)}</span>}
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
