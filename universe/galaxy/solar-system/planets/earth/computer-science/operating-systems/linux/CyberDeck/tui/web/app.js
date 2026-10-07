/* tui web — application glue: state, hash routing, API, DOM.
   Search on top, package detail below. No dependencies. */

"use strict";

(() => {
  const $ = (sel) => document.querySelector(sel);
  const api = {
    async get(path) {
      const res = await fetch(path, { signal: api.signal });
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try {
          const body = await res.json();
          if (body.error) msg = body.error;
        } catch (_) { /* not JSON */ }
        throw new Error(msg);
      }
      return res.json();
    },
  };
  const state = {
    name: null,
    generation: 0,
    detail: null,
    abort: null,
    loading: false,
  };

  const els = {
    search: $("#search"),
    results: $("#results"),
    copyLink: $("#copy-link"),
    commit: $("#commit"),
    status: $("#status"),
    detail: $("#detail"),
    themeSelect: $("#theme-select"),
  };

  /* ---------- themes ---------- */
  function applyTheme(name) {
    document.documentElement.dataset.theme = name;
    els.themeSelect.value = name;
    try {
      localStorage.setItem("tui-theme", name);
    } catch (_) { /* storage unavailable */ }
  }
  els.themeSelect.addEventListener("change", () => applyTheme(els.themeSelect.value));
  let savedTheme = "dark";
  try {
    savedTheme = localStorage.getItem("tui-theme") || "dark";
  } catch (_) { /* storage unavailable */ }
  if (![...els.themeSelect.options].some((o) => o.value === savedTheme)) {
    savedTheme = "dark";
  }
  applyTheme(savedTheme);

  /* ---------- hash routing ---------- */
  function parseHash() {
    const m = /^#\/p\/(.+)$/.exec(location.hash);
    if (!m) return null;
    return decodeURIComponent(m[1]);
  }

  function canonicalHash(name) {
    return `#/p/${encodeURIComponent(name)}`;
  }

  function open(name, { push = true } = {}) {
    if (!name || (name === state.name && !state.loading)) return;
    state.name = name;
    if (push) history.pushState({ name }, "", canonicalHash(name));
    else history.replaceState({ name }, "", canonicalHash(name));
    load(name);
  }

  /* ---------- loading ---------- */
  async function load(name) {
    if (state.abort) state.abort.abort();
    state.abort = new AbortController();
    api.signal = state.abort.signal;
    state.loading = true;
    els.status.textContent = `Loading ${name}…`;

    const detailEl = els.detail;
    detailEl.innerHTML = "";
    for (let i = 0; i < 6; i++) {
      const s = document.createElement("div");
      s.className = "skel";
      s.style.width = `${60 + (i * 13) % 40}%`;
      detailEl.appendChild(s);
    }

    try {
      const detail = await api.get(`/api/v1/package/${encodeURIComponent(name)}`);
      if (state.generation && detail.generation !== state.generation) {
        // Index swapped mid-flight; re-fetch once.
        state.generation = detail.generation;
        return load(name);
      }
      state.generation = detail.generation;
      state.detail = detail;
      renderDetail(detail);
      state.loading = false;
      els.status.textContent = `${detail.name} ${detail.version || ""}`.trim();
    } catch (err) {
      state.loading = false;
      if (err.name === "AbortError") return;
      els.status.textContent = `✗ ${err.message}`;
      detailEl.innerHTML = "";
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = `Could not load "${name}". ${err.message}`;
      detailEl.appendChild(empty);
    }
  }

  /* ---------- detail ---------- */
  function renderDetail(d) {
    const el = els.detail;
    el.innerHTML = "";
    const mk = (tag, cls, text) => {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (text !== undefined) e.textContent = text;
      return e;
    };

    const head = mk("div", "pkg-head");
    head.append(mk("h1", null, d.name));
    if (d.version) head.append(mk("span", "ver", d.version));
    for (const lic of (d.licenses || []).slice(0, 3)) {
      head.append(mk("span", "lic", lic));
    }
    el.append(head);

    if (d.status) el.append(mk("p", "meta", `Status: ${d.status}`));
    if (d.synopsis) el.append(mk("p", "syn", d.synopsis));
    if (d.description) el.append(mk("p", "desc", d.description));
    if (d.homepage) {
      const meta = mk("p", "meta");
      meta.append(mk("span", null, "Home: "));
      const a = document.createElement("a");
      a.href = safeUrl(d.homepage);
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = d.homepage;
      meta.append(a);
      el.append(meta);
    }
    if (d.source_url) {
      const meta = mk("p", "meta");
      meta.append(mk("span", null, "Source: "));
      const a = document.createElement("a");
      a.href = safeUrl(d.source_url);
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = d.source_url;
      meta.append(a);
      el.append(meta);
    }
    if (d.commit) el.append(mk("p", "meta", `Commit: ${d.commit.slice(0, 12)}`));

    const counts = mk("div", "counts");
    const countBox = (label, value) => {
      const box = mk("div", "count");
      box.append(mk("b", null, String(value)));
      box.append(mk("span", null, label));
      return box;
    };
    counts.append(
      countBox("deps", d.deps.length),
      countBox("dependents", d.dependents_count)
    );
    el.append(counts);

    // Related packages: clickable chips.
    const section = (title) => {
      el.append(mk("div", "sec-title", title));
      const wrap = mk("div", "rels");
      el.append(wrap);
      return wrap;
    };

    const depsWrap = section("Dependencies");
    for (const dep of d.deps.slice(0, 24)) {
      depsWrap.append(relChip(dep.name, dep.version, dep.kind));
    }
    if (d.deps.length > 24) depsWrap.append(moreChip(d.deps.length - 24));

    const revWrap = section("Dependents");
    for (const dep of d.dependents.slice(0, 24)) {
      const chip = relChip(dep.name, dep.version);
      const cnt = mk("span", "cnt", `⤴${dep.dependents}`);
      chip.append(cnt);
      revWrap.append(chip);
    }
    if (d.dependents.length > 24) revWrap.append(moreChip(d.dependents.length - 24));

    if (!d.deps.length && !d.dependents.length) {
      el.append(mk("p", "empty", "No related packages found."));
    }
  }

  function relChip(name, version, kind) {
    const chip = document.createElement("button");
    chip.className = "rel";
    const nm = document.createElement("span");
    nm.textContent = name;
    chip.append(nm);
    if (version) {
      const v = document.createElement("span");
      v.className = "r-ver";
      v.textContent = version;
      chip.append(v);
    }
    if (kind === "propagated") chip.append(badge("P", "p"));
    if (kind === "native") chip.append(badge("N", "n"));
    chip.addEventListener("click", () => open(name));
    chip.title = `Open ${name}`;
    return chip;
  }

  function badge(text, cls) {
    const b = document.createElement("span");
    b.className = cls;
    b.textContent = text;
    return b;
  }

  function moreChip(n) {
    const m = document.createElement("span");
    m.className = "more-link";
    m.textContent = `+${n} more`;
    return m;
  }

  function safeUrl(url) {
    try {
      const u = new URL(url);
      if (u.protocol === "http:" || u.protocol === "https:") return url;
    } catch (_) { /* relative or malformed */ }
    return "#";
  }

  /* ---------- search ---------- */
  let searchTimer = null;
  let searchIndex = 0;
  let searchItems = [];

  els.search.addEventListener("input", () => {
    clearTimeout(searchTimer);
    const q = els.search.value.trim();
    if (!q) {
      els.results.hidden = true;
      return;
    }
    searchTimer = setTimeout(() => runSearch(q), 150);
  });

  async function runSearch(q) {
    if (state.abort) state.abort.abort();
    state.abort = new AbortController();
    api.signal = state.abort.signal;
    try {
      const data = await api.get(`/api/v1/search?q=${encodeURIComponent(q)}&limit=20`);
      searchItems = data.items;
      searchIndex = 0;
      renderResults();
    } catch (err) {
      if (err.name === "AbortError") return;
      els.results.hidden = false;
      els.results.innerHTML = "";
      const li = document.createElement("li");
      li.textContent = `✗ ${err.message}`;
      els.results.appendChild(li);
    }
  }

  function renderResults() {
    els.results.innerHTML = "";
    if (!searchItems.length) {
      const li = document.createElement("li");
      li.textContent = "no matches";
      els.results.appendChild(li);
    } else {
      searchItems.forEach((item, i) => {
        const li = document.createElement("li");
        li.setAttribute("role", "option");
        li.setAttribute("aria-selected", String(i === searchIndex));
        const name = spanWithMarks(item.name, item.name_spans);
        name.className = "r-name";
        li.append(name);
        if (item.version) {
          const v = document.createElement("span");
          v.className = "r-ver";
          v.textContent = item.version;
          li.append(v);
        }
        if (item.synopsis) {
          const s = spanWithMarks(item.synopsis, item.synopsis_spans);
          s.className = "r-syn";
          li.append(s);
        }
        li.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          open(item.name);
          els.search.value = "";
          els.results.hidden = true;
        });
        els.results.appendChild(li);
      });
    }
    els.results.hidden = false;
  }

  function spanWithMarks(text, spans) {
    const span = document.createElement("span");
    if (!spans || !spans.length) {
      span.textContent = text;
      return span;
    }
    const chars = Array.from(text);
    let pos = 0;
    for (const [s, e] of spans) {
      if (s > pos) span.append(document.createTextNode(chars.slice(pos, s).join("")));
      const mark = document.createElement("mark");
      mark.textContent = chars.slice(s, e).join("");
      span.append(mark);
      pos = e;
    }
    if (pos < chars.length) {
      span.append(document.createTextNode(chars.slice(pos).join("")));
    }
    return span;
  }

  els.search.addEventListener("keydown", (ev) => {
    if (ev.key === "ArrowDown" && !els.results.hidden) {
      ev.preventDefault();
      searchIndex = (searchIndex + 1) % Math.max(1, searchItems.length);
      renderResults();
    } else if (ev.key === "ArrowUp" && !els.results.hidden) {
      ev.preventDefault();
      searchIndex = (searchIndex - 1 + searchItems.length) % Math.max(1, searchItems.length);
      renderResults();
    } else if (ev.key === "Enter" && !els.results.hidden && searchItems[searchIndex]) {
      ev.preventDefault();
      open(searchItems[searchIndex].name);
      els.search.value = "";
      els.results.hidden = true;
    } else if (ev.key === "Escape") {
      els.results.hidden = true;
    }
  });

  document.addEventListener("click", (ev) => {
    if (!els.search.contains(ev.target) && !els.results.contains(ev.target)) {
      els.results.hidden = true;
    }
  });

  /* ---------- controls ---------- */
  els.copyLink.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(location.href);
      els.copyLink.textContent = "✓";
      setTimeout(() => (els.copyLink.textContent = "⧉"), 1200);
    } catch (_) {
      els.copyLink.textContent = "✗";
      setTimeout(() => (els.copyLink.textContent = "⧉"), 1200);
    }
  });

  /* ---------- history ---------- */
  window.addEventListener("popstate", () => {
    const name = parseHash();
    if (name && name !== state.name) load(name);
  });

  /* ---------- keyboard shortcuts ---------- */
  document.addEventListener("keydown", (ev) => {
    if (ev.target === els.search) return;
    if (ev.key === "/") {
      ev.preventDefault();
      els.search.focus();
    }
  });

  /* ---------- boot ---------- */
  async function boot() {
    const health = await api.get("/api/v1/health");
    if (health.packages > 0) {
      els.commit.textContent = `${health.packages.toLocaleString()} pkgs`;
      if (health.state) {
        els.commit.textContent += ` · ${health.state.slice(0, 7)}`;
      }
    } else if (health.phase === "loading") {
      els.commit.textContent = "snapshot loading…";
      setTimeout(boot, 1500);
      return;
    } else {
      els.commit.textContent = health.phase === "failed" ? "snapshot failed" : "no snapshot";
      els.status.textContent = "Point tui at a snapshot file (--snapshot PATH).";
      return;
    }

    const name = parseHash();
    if (name) {
      load(name);
      history.replaceState({ name }, "", canonicalHash(name));
    } else {
      els.status.textContent = "Search above, or open #/p/<name>.";
    }
  }

  boot().catch((err) => {
    els.status.textContent = `✗ cannot reach API: ${err.message}`;
  });

  // Debug/testing hook (also handy in the browser console).
  window.__tui = { state, els };
})();
