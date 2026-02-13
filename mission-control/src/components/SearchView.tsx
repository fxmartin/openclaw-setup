"use client";

import { useState, useCallback, useEffect, useRef } from "react";

interface SearchResult {
  source: string;
  path: string;
  title: string;
  snippet: string;
  type: string;
  timestamp?: string;
}

export default function SearchView() {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);
  const [indexing, setIndexing] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Auto-focus on mount and on tab switch
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const search = useCallback(async () => {
    if (!query.trim()) return;
    setLoading(true);
    setSearched(true);
    const res = await fetch(`/api/search?q=${encodeURIComponent(query)}`);
    const data = await res.json();
    setResults(data.results);
    setLoading(false);
  }, [query]);

  const reindex = async () => {
    setIndexing(true);
    await fetch("/api/reindex", { method: "POST" });
    setIndexing(false);
  };

  // Highlight matching terms
  const highlight = (snippet: string): string => {
    if (!query.trim()) return snippet;
    // If snippet already has <mark> tags (from FTS), return as-is
    if (snippet.includes("<mark>")) return snippet;
    const words = query.trim().split(/\s+/).filter(Boolean);
    let result = snippet;
    for (const word of words) {
      const re = new RegExp(`(${word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi");
      result = result.replace(re, "<mark>$1</mark>");
    }
    return result;
  };

  return (
    <div>
      <div className="mb-3">
        <h2 className="text-lg font-bold">Search</h2>
        <p className="text-xs" style={{ color: "var(--text-secondary)" }}>
          Memory, files, activity · <kbd className="text-[10px] px-1 py-0.5 rounded" style={{ background: "var(--bg-hover)" }}>⌘K</kbd> or <kbd className="text-[10px] px-1 py-0.5 rounded" style={{ background: "var(--bg-hover)" }}>/</kbd>
        </p>
      </div>

      <div className="flex gap-2 mb-3">
        <input
          ref={inputRef}
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && search()}
          placeholder="Search everything..."
          className="flex-1 px-3 py-2 rounded-lg text-sm outline-none"
          style={{
            background: "var(--bg-card)",
            border: "1px solid var(--border)",
            color: "var(--text-primary)",
          }}
        />
        <button
          onClick={search}
          className="px-4 py-2 rounded-lg text-sm font-medium"
          style={{ background: "var(--accent)", color: "#fff" }}
        >
          {loading ? "..." : "Search"}
        </button>
        <button
          onClick={reindex}
          className="px-3 py-2 rounded-lg text-xs"
          style={{ background: "var(--bg-card)", color: "var(--text-secondary)", border: "1px solid var(--border)" }}
          title="Re-index workspace"
        >
          {indexing ? "⏳" : "🔄"}
        </button>
      </div>

      {searched && (
        <p className="text-xs mb-2" style={{ color: "var(--text-secondary)" }}>
          {results.length} result{results.length !== 1 ? "s" : ""} for &ldquo;{query}&rdquo;
        </p>
      )}

      <div className="space-y-1.5">
        {results.map((r, i) => (
          <div key={i} className="p-3 rounded-lg" style={{ background: "var(--bg-card)" }}>
            <div className="flex items-center gap-2 mb-0.5">
              <span className="text-sm">{r.type === "file" ? "📄" : "⚡"}</span>
              <span className="text-sm font-medium">{r.title}</span>
              {r.path && (
                <span className="text-[10px] font-mono px-1.5 py-0 rounded" style={{ background: "var(--bg-hover)", color: "var(--text-secondary)" }}>
                  {r.path}
                </span>
              )}
            </div>
            <div
              className="text-xs line-clamp-2"
              style={{ color: "var(--text-secondary)" }}
              dangerouslySetInnerHTML={{ __html: highlight(r.snippet) }}
            />
          </div>
        ))}

        {searched && results.length === 0 && !loading && (
          <div className="text-center py-12" style={{ color: "var(--text-secondary)" }}>
            <p className="text-3xl mb-2">🔍</p>
            <p className="text-sm">No results found</p>
          </div>
        )}
      </div>
    </div>
  );
}
