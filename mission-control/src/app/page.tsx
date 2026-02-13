"use client";

import { useState, useEffect, useCallback } from "react";
import ActivityFeed from "@/components/ActivityFeed";
import CalendarView from "@/components/CalendarView";
import SearchView from "@/components/SearchView";

const tabs = [
  { id: "activity", label: "Activity", icon: "⚡" },
  { id: "calendar", label: "Calendar", icon: "📅" },
  { id: "search", label: "Search", icon: "🔍" },
] as const;

type Tab = (typeof tabs)[number]["id"];

function relTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  if (diff < 60000) return "just now";
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
  return `${Math.floor(diff / 86400000)}d ago`;
}

function StatusBar() {
  const [data, setData] = useState<{ todayCount: number; nextJob: string | null; uptime: string }>({
    todayCount: 0,
    nextJob: null,
    uptime: "—",
  });

  const refresh = useCallback(async () => {
    try {
      const [actRes, calRes] = await Promise.all([
        fetch("/api/activity?limit=1"),
        fetch("/api/calendar"),
      ]);
      const act = await actRes.json();
      const cal = await calRes.json();

      // Find next upcoming job
      let nextJob: string | null = null;
      const now = Date.now();
      for (const j of cal.jobs || []) {
        if (j.nextRun) {
          const t = new Date(j.nextRun).getTime();
          if (t > now) {
            nextJob = `${j.name} ${relTime(new Date(now - (t - now)).toISOString()).replace(' ago', '')}`;
            break;
          }
        }
      }

      setData({ todayCount: act.todayCount || 0, nextJob, uptime: "—" });
    } catch { /* ignore */ }
  }, []);

  useEffect(() => {
    refresh();
    const i = setInterval(refresh, 30000);
    return () => clearInterval(i);
  }, [refresh]);

  return (
    <div
      className="flex items-center gap-4 px-4 py-1.5 text-xs border-b shrink-0"
      style={{ background: "var(--bg-secondary)", borderColor: "var(--border)", color: "var(--text-secondary)" }}
    >
      <span>📊 Today: <strong style={{ color: "var(--text-primary)" }}>{data.todayCount}</strong> activities</span>
      {data.nextJob && <span>⏭ Next: <strong style={{ color: "var(--text-primary)" }}>{data.nextJob}</strong></span>}
    </div>
  );
}

export default function Home() {
  const [activeTab, setActiveTab] = useState<Tab>("activity");
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [theme, setTheme] = useState<"dark" | "light">("dark");

  useEffect(() => {
    document.documentElement.className = theme;
  }, [theme]);

  // Global keyboard shortcut
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "/" && !["INPUT", "TEXTAREA"].includes((e.target as HTMLElement).tagName)) {
        e.preventDefault();
        setActiveTab("search");
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setActiveTab("search");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  return (
    <div className="flex flex-col h-screen">
      <StatusBar />
      <div className="flex flex-1 min-h-0">
        {/* Mobile toggle */}
        <button
          onClick={() => setSidebarOpen(!sidebarOpen)}
          className="fixed bottom-4 right-4 z-50 md:hidden w-10 h-10 rounded-full flex items-center justify-center text-lg"
          style={{ background: "var(--accent)", color: "#fff" }}
        >
          {sidebarOpen ? "✕" : "☰"}
        </button>

        {/* Sidebar */}
        <nav
          className={`${sidebarOpen ? "w-48" : "w-0 overflow-hidden"} md:w-48 shrink-0 flex flex-col border-r transition-all`}
          style={{ background: "var(--bg-secondary)", borderColor: "var(--border)" }}
        >
          <div className="p-3 border-b flex items-center justify-between" style={{ borderColor: "var(--border)" }}>
            <h1 className="text-sm font-bold flex items-center gap-1.5">
              <span className="text-lg">🌙</span> Mission Control
            </h1>
            <button
              onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
              className="text-sm opacity-60 hover:opacity-100"
              title="Toggle theme"
            >
              {theme === "dark" ? "☀️" : "🌙"}
            </button>
          </div>
          <div className="flex-1 py-1">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className="w-full text-left px-4 py-2 flex items-center gap-2 text-xs transition-colors"
                style={{
                  background: activeTab === tab.id ? "var(--bg-hover)" : "transparent",
                  color: activeTab === tab.id ? "var(--accent-light)" : "var(--text-secondary)",
                  borderLeft: activeTab === tab.id ? "2px solid var(--accent)" : "2px solid transparent",
                }}
              >
                <span>{tab.icon}</span>
                {tab.label}
              </button>
            ))}
          </div>
          <div className="p-3 text-[10px]" style={{ color: "var(--text-secondary)" }}>
            nyx · <kbd className="opacity-60">/</kbd> search
          </div>
        </nav>

        {/* Main */}
        <main className="flex-1 overflow-auto p-4">
          {activeTab === "activity" && <ActivityFeed />}
          {activeTab === "calendar" && <CalendarView />}
          {activeTab === "search" && <SearchView />}
        </main>
      </div>
    </div>
  );
}
