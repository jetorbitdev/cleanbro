const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

// ---------- i18n ----------
const ID = (navigator.language || "").toLowerCase().startsWith("id");
const L = (en, id) => (ID ? id : en);
const T = {
  cleanSection: L("Clean Up", "Bersihkan"),
  analysis: L("Analysis", "Analisis"),
  home: L("Home", "Beranda"),
  cleanup: L("Junk Files", "File Sampah"),
  uninstall: L("Uninstall Apps", "Uninstall Aplikasi"),
  usage: L("Disk Usage", "Penggunaan Disk"),
  large: L("Large Files", "File Besar"),
  stale: L("Not Modified Lately", "Lama Tak Diubah"),
  dupes: L("Duplicate Files", "File Duplikat"),
};
const CAT = {
  temp: { icon: "clock", name: L("Temporary files", "File sementara") },
  cache: { icon: "box", name: L("App & browser caches", "Cache aplikasi & browser") },
  logs: { icon: "log", name: L("Crash dumps & error reports", "Crash dump & laporan error") },
  dev: { icon: "hammer", name: L("Developer data", "Data developer") },
  dl: { icon: "download", name: L("Incomplete downloads", "Unduhan tidak lengkap") },
  recycle: { icon: "trash", name: L("Recycle Bin", "Recycle Bin") },
};

// ---------- icons (lucide-style strokes) ----------
const ICONS = {
  house: '<path d="M4 11l8-7 8 7"/><path d="M6 10v10h12V10"/><path d="M10 20v-6h4v6"/>',
  sparkles: '<path d="M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
  chart: '<path d="M21 12a9 9 0 1 1-9-9v9z"/><path d="M15 3.5A9 9 0 0 1 20.5 9H15z"/>',
  file: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h8"/>',
  box: '<path d="M21 8l-9-5-9 5 9 5z"/><path d="M3 8v8l9 5 9-5V8"/><path d="M12 13v8"/>',
  log: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M9 13h6M9 17h4"/>',
  hammer: '<path d="M15 12l-8.5 8.5a2.1 2.1 0 0 1-3-3L12 9"/><path d="M17.6 15L22 10.6l-6.6-6.6L11 8.4"/>',
  download: '<circle cx="12" cy="12" r="9" stroke-dasharray="3 3"/><path d="M12 8v8M8.5 12.5L12 16l3.5-3.5"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6"/><path d="M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  apps: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  drive: '<rect x="3" y="13" width="18" height="7" rx="2"/><path d="M5 13l2.5-8h9L19 13"/><path d="M7 16.5h.01M11 16.5h.01"/>',
  check: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.8"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  warn: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.5h.01"/>',
  back: '<path d="M15 6l-6 6 6 6"/>',
  chev: '<path d="M9 6l6 6-6 6"/>',
  up: '<path d="M12 19V5M6 11l6-6 6 6"/>',
};
const svg = (name, cls = "") =>
  `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[name]}</svg>`;

// ---------- helpers ----------
const nf1 = new Intl.NumberFormat(ID ? "id-ID" : "en-US", { maximumFractionDigits: 1, minimumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat(ID ? "id-ID" : "en-US", { maximumFractionDigits: 0 });
function fmt(n) {
  if (!n) return L("Zero KB", "Nol KB");
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${i < 2 ? nf0.format(n) : nf1.format(n)} ${u[i]}`;
}
const count = (n) => nf0.format(n);
const fmtDate = (s) => (s ? new Date(s * 1000).toLocaleDateString(ID ? "id-ID" : undefined, { year: "numeric", month: "short", day: "numeric" }) : "");
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function h(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}
function parent(p) {
  const i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  if (i <= 0) return p.slice(0, 1) === "/" ? "/" : p;
  const up = p.slice(0, i);
  return /^[A-Za-z]:$/.test(up) ? up + "\\" : up;
}
const baseName = (p) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || p;
const isDriveRoot = (p) => /^[A-Za-z]:\\?$/.test(p);
const samePath = (a, b) => a.replace(/[\\/]+$/, "").toLowerCase() === b.replace(/[\\/]+$/, "").toLowerCase();
const inside = (p, dir) => p.toLowerCase().startsWith(dir.replace(/[\\/]+$/, "").toLowerCase() + "\\");
function summary(names) {
  if (!names.length) return L("Already clean", "Sudah bersih");
  const top = names.slice(0, 3).join(", ");
  const rest = names.length - 3;
  return rest > 0 ? L(`${top}, and ${rest} more`, `${top}, dan ${rest} lainnya`) : top;
}
const loading = (text) => `<div class="loading"><div class="spin"></div>${esc(text)}</div>`;

// ---------- state ----------
const freshDupes = (skip = true) => ({ phase: "idle", groups: [], partial: false, progress: null, skip, min: 1 << 20 });
const state = {
  tab: "home",
  home: "",
  vol: null, // { name, total, free }
  gen: 0, // bumps on every navigation; late results from an old page are dropped
  // Junk Files: idle -> scanning -> done -> finished, like the macOS app
  junkPhase: "idle",
  junk: null,
  junkSel: new Set(),
  junkPartial: false,
  junkProgress: null,
  junkError: "",
  freed: 0,
  cleanFailed: [],
  open: new Set(),
  // one analysis scan feeds Home, Disk Usage, Large, Stale and Duplicates
  scan: { phase: "idle", root: "", sum: null, progress: null, error: "" },
  files: null, // files of 1 MB or more from the last scan
  usagePath: null,
  homeFocus: null, // null | { kind: "cat", id } | { kind: "node", path }
  homeCache: new Map(),
  marks: new Map(), // Home: path -> { name, size }
  dupe: freshDupes(),
  sel: new Set(), // checked paths
  hl: new Set(), // highlighted rows (click / ctrl / shift), toggled with Space
  anchor: -1,
  visible: [], // rows the open table shows, for the selection bar
  paint: null, // redraws the open table's visible rows
  ro: null,
  usageCache: null, // { path, items, info } of the Disk Usage folder
  sort: { usage: { key: "size", dir: "desc" }, large: { key: "size", dir: "desc" }, stale: { key: "modified", dir: "asc" } },
  f: {
    large: { min: 100 << 20, kind: null, q: "" },
    stale: { age: 12, min: 10 << 20, skipApp: true, q: "" },
    dupes: { q: "" },
  },
  note: "",
  apps: null,
  app: null, // the app being uninstalled: { info, phase, leftovers, sel }
  appQuery: "",
};

function setFooter(left, right) {
  $("foot-left").replaceChildren(...left);
  $("foot-right").replaceChildren(...right);
}
function button(text, onClick, primary = false, disabled = false) {
  const b = h(`<button class="btn${primary ? " primary" : ""}">${esc(text)}</button>`);
  b.disabled = disabled;
  b.onclick = onClick;
  return b;
}
function toast(text) {
  const t = h(`<div class="toast">${esc(text)}</div>`);
  document.body.append(t);
  setTimeout(() => t.remove(), 3200);
}

// ---------- sidebar ----------
function initSidebar() {
  document.querySelectorAll("[data-l]").forEach((e) => (e.textContent = T[e.dataset.l]));
  document.querySelectorAll("[data-icon]").forEach((e) => (e.innerHTML = svg(e.dataset.icon)));
  document.querySelectorAll(".nav").forEach((b) => (b.onclick = () => show(b.dataset.tab)));
}
/// sidebar numbers, as on macOS
function updateBadges() {
  const set = (tab, text) => { const e = document.querySelector(`.nav[data-tab="${tab}"] em`); if (e) e.textContent = text; };
  set("cleanup", state.junkPhase === "done" ? fmt(junkSelectedSize()) : "");
  set("uninstall", state.apps ? String(state.apps.length) : "");
  const s = state.scan.sum;
  set("usage", state.scan.phase === "done" && s ? fmt(s.size) : "");
  set("large", state.files ? String(largeStats().count) : "");
  set("dupes", state.dupe.phase === "done" ? fmt(state.dupe.groups.reduce((t, g) => t + g.wasted, 0)) : "");
}
async function refreshDisk() {
  const d = await invoke("disk_info", { path: state.home }).catch(() => null);
  if (!d) return;
  state.vol = d;
  $("disk").hidden = false;
  $("disk-name").textContent = d.name;
  $("disk-free").textContent = L(`${fmt(d.free)} free`, `${fmt(d.free)} kosong`);
  $("disk-bar").style.width = `${((d.total - d.free) / d.total) * 100}%`;
  $("disk-bar").classList.toggle("full", (d.total - d.free) / d.total > 0.9);
  $("disk-used").textContent = L(`${fmt(d.total - d.free)} of ${fmt(d.total)} used`, `${fmt(d.total - d.free)} dari ${fmt(d.total)} terpakai`);
}

// ---------- long jobs: progress polling ----------
/// Polls a running job's counters until the returned stop function is called.
function poll(kind, onTick) {
  let alive = true;
  const tick = async () => {
    if (!alive) return;
    const p = await invoke("job_progress", { kind }).catch(() => null);
    if (!alive) return;
    if (p) onTick(p);
    setTimeout(tick, 200);
  };
  setTimeout(tick, 120);
  return () => { alive = false; };
}
const JOB_TABS = {
  analysis: ["home", "usage", "large", "stale", "dupes"],
  junk: ["cleanup", "home"],
  dupes: ["dupes"],
};
/// Redraws the open tab if it shows `kind`. Progress ticks only redraw the
/// tab that shows the live counters, not the ones that merely mention the job.
function repaintFor(kind, tick = false) {
  const tabs = tick && kind === "junk" ? ["cleanup"] : JOB_TABS[kind];
  if (tabs.includes(state.tab)) repaint();
}

// ---------- shared screens (idle / scanning / banners) ----------
function panel({ ring, title, text, extra = [], actions = [] }) {
  const el = h(`<div class="panel">
    <div class="ring">${ring}</div>
    <h2>${esc(title)}</h2>
    ${text ? `<p>${esc(text)}</p>` : ""}
  </div>`);
  el.append(...extra);
  if (actions.length) {
    const row = h(`<div class="actions"></div>`);
    row.append(...actions);
    el.append(row);
  }
  return el;
}
/// Live progress screen of `job`. Built once, then only its numbers change, so
/// the bar animates on instead of restarting at every progress tick.
function scanningView(job, { big, frac, line, current, stopping, onStop }) {
  let el = $("content").querySelector(`:scope > .panel[data-job="${job}"]`);
  if (!el) {
    el = h(`<div class="panel" data-job="${job}">
      <div class="bignum"></div>
      <div class="pbar${frac == null ? " ind" : ""}"><div></div></div>
      <div class="line"></div>
      <div class="cur"></div>
      <div class="stop"></div>
    </div>`);
    $("content").replaceChildren(el);
  }
  el.querySelector(".bignum").textContent = big;
  if (frac != null) el.querySelector(".pbar > div").style.width = `${Math.round(frac * 100)}%`;
  el.querySelector(".line").textContent = line || "";
  el.querySelector(".cur").textContent = current || "";
  const stop = el.querySelector(".stop");
  if (stop.dataset.stopping !== String(!!stopping)) {
    stop.dataset.stopping = String(!!stopping);
    stop.replaceChildren(stopping
      ? h(`<div class="stopping"><div class="spin"></div>${L("Stopping…", "Menghentikan…")}</div>`)
      : button(L("Stop & Show Results", "Berhenti & Tampilkan Hasil"), onStop));
  }
}
function banner(text, onFull) {
  const b = h(`<div class="banner">${svg("warn", "ic")}<span>${esc(text)}</span></div>`);
  if (onFull) b.append(button(L("Full Scan", "Pindai Lengkap"), onFull));
  return b;
}
function chip(title, on, onClick) {
  const c = h(`<button class="chip${on ? " on" : ""}">${esc(title)}</button>`);
  c.onclick = onClick;
  return c;
}
function showPanel(el) {
  $("hero").innerHTML = "";
  setFooter([], []);
  $("content").replaceChildren(el);
}

// ---------- Junk Files ----------
const junkSelectedSize = () =>
  (state.junk || []).flatMap((c) => c.items).filter((i) => state.junkSel.has(i.path)).reduce((s, i) => s + i.size, 0);

async function startJunk() {
  if (state.junkPhase === "scanning") return;
  state.junkPhase = "scanning";
  state.junkProgress = null;
  state.junkError = "";
  state.note = "";
  updateBadges();
  repaintFor("junk");
  const stop = poll("junk", (p) => { state.junkProgress = p; repaintFor("junk", true); });
  const r = await invoke("scan_junk").catch((e) => ({ error: String(e) }));
  stop();
  if (r.error) {
    state.junkPhase = "idle";
    state.junkError = r.error;
  } else {
    state.junk = r.cats;
    state.junkPartial = r.partial;
    state.junkSel = new Set(r.cats.filter((c) => c.id !== "recycle").flatMap((c) => c.items.map((i) => i.path)));
    state.junkPhase = "done";
  }
  updateBadges();
  repaintFor("junk");
}

function cleanup() {
  switch (state.junkPhase) {
    case "idle":
      return showPanel(panel({
        ring: `<span class="ready">${L("Ready", "Siap")}</span>`,
        title: L("Find junk files on your PC", "Temukan file sampah di PC Anda"),
        text: state.junkError || L("Temporary files, caches, crash dumps, developer data, leftover downloads, and Recycle Bin contents will be scanned. Nothing is deleted until you confirm.",
          "File sementara, cache, crash dump, data developer, sisa unduhan, dan isi Recycle Bin akan dipindai. Tidak ada yang dihapus sebelum Anda konfirmasi."),
        actions: [button(L("Scan", "Pindai"), startJunk, true)],
      }));
    case "scanning": {
      const p = state.junkProgress;
      const frac = p && p.total ? p.done / p.total : 0;
      $("hero").innerHTML = "";
      setFooter([], []);
      return scanningView("junk", {
        big: `${Math.floor(frac * 100)}%`, frac, current: p?.current, stopping: p?.stopping,
        onStop: () => invoke("cancel_job", { kind: "junk" }),
      });
    }
    case "finished":
      return cleanFinished();
    default:
      return renderCleanup();
  }
}

function renderCleanup() {
  const cats = state.junk;
  const selSize = junkSelectedSize();
  $("hero").innerHTML = `<div class="big"><b>${fmt(selSize)}</b><span>${L("can be cleaned up", "bisa dibersihkan")}</span></div>`;

  const rows = [];
  if (state.junkPartial) {
    rows.push(banner(L("Scan stopped. This list only contains items that were fully measured.",
      "Pemindaian dihentikan. Daftar ini hanya berisi item yang sudah selesai diukur."), startJunk));
  }
  for (const c of cats) {
    const meta = CAT[c.id] || { icon: "box", name: c.id };
    const size = c.items.reduce((s, i) => s + i.size, 0);
    const nSel = c.items.filter((i) => state.junkSel.has(i.path)).length;
    const open = state.open.has(c.id) && c.items.length;
    const desc = c.needs_access && !c.items.length ? L("Needs administrator rights", "Butuh hak administrator") : summary(c.items.map((i) => i.name));
    const row = h(`<div class="row click${open ? " open" : ""}">
      <input type="checkbox" class="cb">
      ${svg(meta.icon, "ic")}
      <div class="txt"><b>${esc(meta.name)}</b><small>${esc(desc)}</small></div>
      ${c.needs_access ? `<span class="pill">${L("Admin", "Admin")}</span>` : ""}
      <span class="size">${fmt(size)}</span>
      ${c.items.length ? svg("chev", "chev") : '<span style="width:14px"></span>'}
    </div>`);
    if (!c.items.length) row.classList.remove("click");
    const cb = row.querySelector(".cb");
    cb.disabled = !c.items.length;
    cb.checked = c.items.length > 0 && nSel === c.items.length;
    cb.indeterminate = nSel > 0 && nSel < c.items.length;
    cb.onclick = (e) => {
      e.stopPropagation();
      const all = nSel === c.items.length;
      c.items.forEach((i) => (all ? state.junkSel.delete(i.path) : state.junkSel.add(i.path)));
      updateBadges();
      renderCleanup();
    };
    row.onclick = () => {
      if (!c.items.length) return;
      state.open.has(c.id) ? state.open.delete(c.id) : state.open.add(c.id);
      renderCleanup();
    };
    rows.push(row);
    if (open) {
      for (const i of c.items) {
        const sub = h(`<div class="row sub click">
          <input type="checkbox" class="cb">
          <div class="txt"><b>${esc(i.name)}</b></div>
          <span class="size">${fmt(i.size)}</span>
        </div>`);
        const scb = sub.querySelector(".cb");
        scb.checked = state.junkSel.has(i.path);
        sub.onclick = (e) => {
          if (e.target !== scb) scb.checked = !scb.checked;
          scb.checked ? state.junkSel.add(i.path) : state.junkSel.delete(i.path);
          updateBadges();
          renderCleanup();
        };
        rows.push(sub);
      }
    }
  }
  const scroll = $("content").scrollTop;
  $("content").replaceChildren(...rows);
  $("content").scrollTop = scroll;

  setFooter(
    [button(L("Rescan", "Pindai Ulang"), startJunk)],
    [button(L(`Clean ${fmt(selSize)}`, `Bersihkan ${fmt(selSize)}`), runClean, true, !selSize)],
  );
}

async function runClean() {
  const paths = [...state.junkSel];
  if (!paths.length) return;
  if (!confirm(L(`Permanently delete ${paths.length} item(s)? This cannot be undone.`, `Hapus permanen ${paths.length} item? Tindakan ini tidak bisa dibatalkan.`))) return;
  $("content").innerHTML = loading(L("Cleaning…", "Membersihkan…"));
  setFooter([], []);
  const r = await invoke("clean_junk", { paths }).catch((e) => ({ freed: 0, failed: [[paths[0], String(e)]] }));
  state.freed = r.freed;
  state.cleanFailed = r.failed;
  state.junkPhase = "finished";
  state.junk = null;
  state.junkSel.clear();
  updateBadges();
  refreshDisk();
  repaintFor("junk");
}

function cleanFinished() {
  const extra = [];
  if (state.cleanFailed.length) {
    const list = h(`<div class="fails"><b>${L(`${state.cleanFailed.length} item(s) were in use and skipped`, `${state.cleanFailed.length} item sedang dipakai dan dilewati`)}</b></div>`);
    for (const [p] of state.cleanFailed.slice(0, 6)) list.append(h(`<small>${esc(p)}</small>`));
    extra.push(list);
  }
  showPanel(panel({
    ring: svg("check", "ok"),
    title: L(`${fmt(state.freed)} freed`, `${fmt(state.freed)} dikosongkan`),
    text: L("Files were permanently deleted, bypassing the Recycle Bin.", "File dihapus permanen, tanpa melewati Recycle Bin."),
    extra,
    actions: [button(L("Back", "Kembali"), () => { state.junkPhase = "idle"; repaint(); })],
  }));
  $("content").querySelector(".ring").classList.add("done");
}

// ---------- Uninstall Apps ----------
async function uninstall() {
  if (state.app) return uninstallDetail();
  const g = state.gen;
  if (!state.apps) {
    $("content").innerHTML = loading(L("Reading installed apps…", "Membaca aplikasi terpasang…"));
    const apps = await invoke("list_apps").catch(() => []);
    if (g !== state.gen) return;
    state.apps = apps;
  }
  const q = h(`<input class="field" spellcheck="false" placeholder="${L("Search apps", "Cari aplikasi")}">`);
  q.value = state.appQuery;
  q.oninput = () => { state.appQuery = q.value; renderApps(); };
  $("hero").replaceChildren(h(`<div class="big"><b>${state.apps.length}</b><span>${L("installed apps", "aplikasi terpasang")}</span></div>`), (() => {
    const bar = h(`<div class="toolbar"></div>`);
    bar.append(q);
    return bar;
  })());
  setFooter(state.note ? [h(`<span>${esc(state.note)}</span>`)] : [], []);
  renderApps();
}

function renderApps() {
  const q = state.appQuery.trim().toLowerCase();
  const list = state.apps.filter((a) => !q || (a.name + " " + a.publisher).toLowerCase().includes(q));
  if (!list.length) {
    $("content").innerHTML = `<div class="empty">${state.apps.length ? L("No match", "Tidak ada yang cocok") : L("No apps found", "Tidak ada aplikasi")}</div>`;
    return;
  }
  $("content").replaceChildren(...list.map((a) => {
    const meta = [a.version, a.publisher].filter(Boolean).join(" · ");
    const row = h(`<div class="row click">
      ${svg("apps", "ic")}
      <div class="txt"><b>${esc(a.name)}</b><small>${esc(meta)}</small></div>
      <span class="size">${a.size ? fmt(a.size) : ""}</span>
      ${svg("chev", "chev")}
    </div>`);
    row.onclick = () => openApp(a);
    return row;
  }));
}

function openApp(info) {
  state.app = { info, phase: "review", leftovers: null, sel: new Set() };
  show("uninstall", true);
}

async function loadLeftovers() {
  const ap = state.app;
  const g = state.gen;
  const items = await invoke("app_leftovers", { id: ap.info.id }).catch(() => []);
  if (g !== state.gen || state.app !== ap) return;
  ap.leftovers = items;
  ap.sel = new Set(items.map((i) => i.path));
  uninstallDetail();
}

function uninstallDetail() {
  const ap = state.app;
  const info = ap.info;
  const left = ap.leftovers;
  const total = (left || []).reduce((s, i) => s + i.size, 0);
  const meta = [info.version, info.publisher].filter(Boolean).join(" · ");
  $("hero").innerHTML = `<div class="big"><b style="font-size:22px">${esc(info.name)}</b><span>${esc(meta)}</span></div>`;

  if (left === null) {
    $("content").innerHTML = loading(L("Looking for leftover files…", "Mencari sisa file…"));
    setFooter([button(L("Back", "Kembali"), backToApps)], []);
    loadLeftovers();
    return;
  }

  const rows = [];
  rows.push(h(`<div class="group-head"><span>${ap.phase === "done" ? L("Leftover files", "Sisa file") : L("Will also be offered for removal", "Akan ditawarkan untuk dihapus")}</span><span>${left.length ? fmt(total) : ""}</span></div>`));
  if (!left.length) rows.push(h(`<div class="empty">${L("No leftover files found", "Tidak ada sisa file")}</div>`));
  for (const i of left) {
    const row = h(`<div class="row click">
      <input type="checkbox" class="cb">
      ${svg("folder", "ic")}
      <div class="txt"><b>${esc(i.name)}</b><small>${esc(i.path)}</small></div>
      <span class="pill">${esc(i.place)}</span>
      <span class="size">${fmt(i.size)}</span>
    </div>`);
    const cb = row.querySelector(".cb");
    cb.checked = ap.sel.has(i.path);
    row.onclick = (e) => {
      if (e.target !== cb) cb.checked = !cb.checked;
      cb.checked ? ap.sel.add(i.path) : ap.sel.delete(i.path);
      uninstallDetail();
    };
    rows.push(row);
  }
  $("content").replaceChildren(...rows);

  const selSize = left.filter((i) => ap.sel.has(i.path)).reduce((s, i) => s + i.size, 0);
  if (ap.phase === "review") {
    setFooter(
      [button(L("Back", "Kembali"), backToApps)],
      [button(L("Uninstall…", "Uninstall…"), runUninstall, true)],
    );
  } else {
    setFooter(
      [button(L("Done", "Selesai"), backToApps), ...(ap.note ? [h(`<span>${esc(ap.note)}</span>`)] : [])],
      [button(selSize ? L(`Remove ${fmt(selSize)}`, `Hapus ${fmt(selSize)}`) : L("Remove", "Hapus"), removeLeftovers, true, !ap.sel.size)],
    );
  }
}

function backToApps() {
  state.app = null;
  state.apps = null; // the list changed if something was uninstalled
  show("uninstall", true);
}

async function runUninstall() {
  const ap = state.app;
  if (!confirm(L(`Run the uninstaller for ${ap.info.name}?`, `Jalankan uninstaller untuk ${ap.info.name}?`))) return;
  $("content").innerHTML = loading(L("Waiting for the uninstaller to finish…", "Menunggu uninstaller selesai…"));
  setFooter([], []);
  try {
    const code = await invoke("run_uninstall", { id: ap.info.id });
    ap.note = code === 0 ? "" : L(`The uninstaller exited with code ${code}`, `Uninstaller berakhir dengan kode ${code}`);
  } catch (err) {
    ap.note = String(err);
  }
  ap.phase = "done";
  ap.leftovers = null; // look again: the uninstaller removes some of them itself
  uninstallDetail();
}

async function removeLeftovers() {
  const ap = state.app;
  const paths = [...ap.sel];
  if (!paths.length || !confirm(L(`Permanently delete ${paths.length} item(s)? This cannot be undone.`, `Hapus permanen ${paths.length} item? Tindakan ini tidak bisa dibatalkan.`))) return;
  $("content").innerHTML = loading(L("Removing…", "Menghapus…"));
  setFooter([], []);
  const r = await invoke("delete_leftovers", { id: ap.info.id, paths });
  ap.note = L(`Freed ${fmt(r.freed)}`, `${fmt(r.freed)} dibebaskan`) +
    (r.failed.length ? L(` · ${r.failed.length} could not be removed`, ` · ${r.failed.length} gagal dihapus`) : "");
  refreshDisk();
  ap.leftovers = null;
  uninstallDetail();
}

// ---------- analysis scan (Home, Disk Usage, Large, Stale, Duplicates) ----------
const drive = () => state.home.match(/^[A-Za-z]:\\/)?.[0] || "C:\\";
function presets() {
  const d = drive();
  return [
    { title: L("Home", "Home"), path: state.home },
    { title: "AppData", path: state.home + "\\AppData" },
    { title: "Program Files", path: d + "Program Files" },
    { title: state.vol?.name || `Local Disk (${d.slice(0, 2)})`, path: d },
  ];
}
const largeStats = () => (state.files || []).reduce((a, f) => (f.size >= 100 << 20 ? { count: a.count + 1, size: a.size + f.size } : a), { count: 0, size: 0 });

async function chooseFolder() {
  const picked = await invoke("plugin:dialog|open", {
    options: { directory: true, defaultPath: state.scan.root || state.home, title: L("Choose a folder or drive to analyze", "Pilih folder atau drive yang ingin dianalisis") },
  }).catch(() => null);
  if (typeof picked === "string" && picked) startAnalysis(picked);
}

async function startAnalysis(root = state.scan.root) {
  if (state.scan.phase === "scanning") return;
  state.scan = { phase: "scanning", root, sum: null, progress: null, error: "" };
  state.files = null;
  state.dupe = freshDupes(state.dupe.skip);
  state.marks.clear();
  state.homeCache.clear();
  state.usagePath = null;
  state.usageCache = null;
  state.hl.clear();
  state.homeFocus = null;
  updateBadges();
  repaintFor("analysis");
  const job = state.scan;
  const stop = poll("analysis", (p) => { job.progress = p; repaintFor("analysis", true); });
  const r = await invoke("start_analysis", { root }).catch((e) => ({ error: String(e) }));
  stop();
  state.scan = r.error
    ? { phase: "idle", root, sum: null, progress: null, error: r.error }
    : { phase: "done", root: r.root, sum: r, progress: job.progress, error: "" };
  state.files = r.error ? null : r.big;
  updateBadges();
  refreshDisk();
  repaintFor("analysis");
}

/// The idle / scanning screens every analysis tool shares. True when the scan
/// is done and the tool can draw its results.
function gate(keepHero = false) {
  const s = state.scan;
  if (s.phase === "done") return true;
  if (!keepHero) $("hero").innerHTML = "";
  setFooter([], []);
  if (s.phase === "scanning") {
    const p = s.progress;
    // a whole drive: bytes read out of the space in use; a folder: finished
    // subfolders (see PROGRESS_TOTAL in scan.rs). Never goes back, and stays
    // under 100% until the scan really ends.
    const used = state.vol ? state.vol.total - state.vol.free : 0;
    const raw = !p ? 0 : isDriveRoot(s.root) && used > 0 ? p.bytes / used : p.total ? p.done / p.total : 0;
    s.frac = Math.min(0.99, Math.max(s.frac || 0, raw));
    const pct = Math.floor(s.frac * 100);
    scanningView("analysis", {
      big: fmt(p?.bytes || 0), frac: s.frac,
      line: p ? L(`${pct}% · ${count(p.dirs)} ${p.dirs === 1 ? "folder" : "folders"} · ${count(p.files)} ${p.files === 1 ? "file" : "files"}`, `${pct}% · ${count(p.dirs)} folder · ${count(p.files)} file`) : "",
      current: p?.current, stopping: p?.stopping,
      onStop: () => invoke("cancel_job", { kind: "analysis" }),
    });
    return false;
  }
  const chips = h(`<div class="chips"></div>`);
  chips.append(...presets().map((p) => chip(p.title, samePath(s.root, p.path), () => { s.root = p.path; repaint(); })));
  const el = panel({
    ring: svg("drive", "big-ic"),
    title: L("Analyze Disk Usage", "Analisis penggunaan disk"),
    text: L(`CleanBro will measure every folder and file in ${s.root}, then show the largest ones and those that haven't been modified in a long time.`,
      `CleanBro akan menghitung ukuran setiap folder dan file di ${s.root}, lalu menampilkan yang terbesar dan yang sudah lama tidak diubah.`),
    extra: [chips, ...(s.error ? [h(`<div class="err">${esc(s.error)}</div>`)] : [])],
    actions: [button(L("Choose Folder…", "Pilih Folder…"), chooseFolder), button(L("Scan", "Pindai"), () => startAnalysis(), true)],
  });
  $("content").replaceChildren(el);
  return false;
}

/// Shown above results of a scan the user stopped.
function partialBanner() {
  if (!state.scan.sum?.partial) return [];
  const p = state.scan.progress || { dirs: 0, files: 0 };
  return [banner(L(`Scan stopped. Results only include the ${count(p.dirs)} folders and ${count(p.files)} files read so far. Sizes are incomplete.`,
    `Pemindaian dihentikan. Hasil hanya mencakup ${count(p.dirs)} folder dan ${count(p.files)} file yang sudah dibaca. Ukuran belum lengkap.`), () => startAnalysis())];
}

/// Folder picker + Rescan, the macOS toolbar of every analysis tool.
function scanTools() {
  const wrap = h(`<div class="menu-wrap"></div>`);
  const pick = h(`<button class="btn tool">${svg("folder", "")}<span>${esc(state.scan.sum?.root || state.scan.root)}</span></button>`);
  pick.title = L("Choose the folder to scan", "Pilih folder yang dipindai");
  const menu = h(`<div class="menu" hidden></div>`);
  for (const p of presets()) {
    const it = h(`<button>${esc(p.title)}<small>${esc(p.path)}</small></button>`);
    it.onclick = () => startAnalysis(p.path);
    menu.append(it);
  }
  menu.append(h(`<hr>`));
  const choose = h(`<button>${L("Choose Folder…", "Pilih Folder…")}</button>`);
  choose.onclick = chooseFolder;
  menu.append(choose);
  pick.onclick = (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
    if (!menu.hidden) document.addEventListener("click", () => (menu.hidden = true), { once: true });
  };
  wrap.append(pick, menu);
  const re = h(`<button class="btn tool" title="${L("Rescan", "Pindai ulang")}">${svg("refresh", "")}<span>${L("Rescan", "Pindai Ulang")}</span></button>`);
  re.onclick = () => startAnalysis(state.scan.sum?.root || state.scan.root);
  return [wrap, re];
}

// ---------- Home ----------
const PALETTE = ["#3b6b9e", "#6ba178", "#b8945c", "#856ea8", "#218587", "#b56b78", "#66758f"];
const CATS = {
  users: { title: L("Users", "Pengguna"), color: "#3b6b9e", help: L("User folders in C:\\Users", "Folder pengguna di C:\\Users") },
  apps: { title: L("Applications", "Aplikasi"), color: "#b8945c", help: L("Programs in Program Files", "Program di Program Files") },
  system: { title: L("System", "Sistem"), color: "#6ba178", help: L("Windows, ProgramData and other system folders", "Windows, ProgramData dan folder sistem lain") },
  other: {
    title: L("Other Space", "Ruang lain"), color: "#c4c4c4", light: true,
    help: L("Space in use that the scan couldn't read: folders without permission, System Volume Information, restore points, and files Windows keeps open",
      "Ruang terpakai yang tidak bisa dibaca pemindaian: folder tanpa izin, System Volume Information, titik pemulihan, dan file yang dibuka Windows"),
  },
};

/// Squarified treemap: one rectangle per size (largest first), areas
/// proportional to the sizes, aspect ratios close to square.
function squarify(sizes, x, y, w, hh) {
  const out = sizes.map(() => ({ x: 0, y: 0, w: 0, h: 0 }));
  const total = sizes.reduce((s, v) => s + Math.max(0, v), 0);
  if (total <= 0 || w <= 1 || hh <= 1) return out;
  const scale = (w * hh) / total;
  const areas = sizes.map((v) => Math.max(0, v) * scale);
  const worst = (sum, lo, hi, side) => {
    if (lo <= 0 || sum <= 0) return Infinity;
    const s2 = side * side, sum2 = sum * sum;
    return Math.max((s2 * hi) / sum2, sum2 / (s2 * lo));
  };
  let r = { x, y, w, h: hh };
  let i = 0;
  while (i < areas.length) {
    const side = Math.min(r.w, r.h);
    if (side <= 0) break;
    let j = i + 1, sum = areas[i], lo = areas[i], hi = areas[i];
    let cur = worst(sum, lo, hi, side);
    while (j < areas.length) {
      const a = areas[j];
      const next = worst(sum + a, Math.min(lo, a), Math.max(hi, a), side);
      if (next > cur) break;
      sum += a; lo = Math.min(lo, a); hi = Math.max(hi, a); cur = next;
      j++;
    }
    if (sum <= 0) break;
    const thick = sum / side;
    if (r.w >= r.h) {
      let yy = r.y;
      for (let k = i; k < j; k++) { const bh = areas[k] / thick; out[k] = { x: r.x, y: yy, w: thick, h: bh }; yy += bh; }
      r = { x: r.x + thick, y: r.y, w: Math.max(0, r.w - thick), h: r.h };
    } else {
      let xx = r.x;
      for (let k = i; k < j; k++) { const bw = areas[k] / thick; out[k] = { x: xx, y: r.y, w: bw, h: thick }; xx += bw; }
      r = { x: r.x, y: r.y + thick, w: r.w, h: Math.max(0, r.h - thick) };
    }
    i = j;
  }
  return out;
}

const toBlock = (e) => ({
  id: e.path, name: e.name, size: e.size, path: e.path,
  target: e.is_dir && e.size > 0 ? { kind: "node", path: e.path } : null,
  raw: e.children || [],
});
/// Keeps the biggest blocks and folds the rest into one "Other" block.
function group(items, total, max, minFrac, id) {
  const floor = total * minFrac;
  const kept = [];
  let rest = 0;
  for (const b of [...items].sort((a, b) => b.size - a.size)) {
    if (kept.length < max && b.size >= floor && b.size > 0) kept.push(b); else rest += b.size;
  }
  rest += Math.max(0, total - kept.reduce((s, b) => s + b.size, 0) - rest);
  if (rest > 0 && rest >= total * 0.004) {
    kept.push({ id: id + "#other", name: L("Other", "Lainnya"), size: rest, color: "#d6d6d6", light: true });
    kept.sort((a, b) => b.size - a.size);
  }
  return kept;
}
function shade(kids, parentBlock) {
  return kids.map((k, i) => (k.path ? { ...k, color: parentBlock.color, light: parentBlock.light, shade: 0.12 + 0.07 * (i % 4) } : k));
}
/// Colors the top blocks and fills each folder with its own contents.
function nest(top) {
  let i = 0;
  return top.map((b) => {
    const out = { ...b };
    if (b.path) out.color = PALETTE[i++ % PALETTE.length];
    if (b.target && b.raw?.length) out.children = shade(group(b.raw.map(toBlock), b.size, 10, 0.03, b.id), out);
    return out;
  });
}

const kids = (path, nested = false) => invoke("tree_children", { path, nested }).catch(() => null);

/// Disk categories for a scan of a whole drive: entries per category.
async function categories(nested) {
  const root = state.scan.sum.root;
  const top = await kids(root);
  if (!top) return null;
  const rootSize = top.reduce((s, e) => s + e.size, 0);
  const users = top.find((e) => e.is_dir && e.name.toLowerCase() === "users");
  const apps = top.filter((e) => e.is_dir && /^program files( \(x86\))?$/i.test(e.name));
  const userRaw = [];
  if (users) {
    for (const e of (await kids(users.path, nested)) || []) {
      if (samePath(e.path, state.home)) userRaw.push(...((await kids(state.home, nested)) || []));
      else userRaw.push(e);
    }
  }
  const appRaw = [];
  for (const a of apps) appRaw.push(...((await kids(a.path, nested)) || []));
  let sysRaw = top.filter((e) => e !== users && !apps.includes(e));
  if (nested) sysRaw = ((await kids(root, true)) || []).filter((e) => !(users && samePath(e.path, users.path)) && !apps.some((a) => samePath(a.path, e.path)));
  const usersSize = users?.size || 0, appsSize = apps.reduce((s, a) => s + a.size, 0);
  const used = state.vol ? state.vol.total - state.vol.free : 0;
  return [
    { id: "users", size: usersSize, raw: userRaw },
    { id: "apps", size: appsSize, raw: appRaw },
    { id: "system", size: Math.max(0, rootSize - usersSize - appsSize), raw: sysRaw },
    { id: "other", size: Math.max(0, used - rootSize), raw: [] },
  ];
}

/// Blocks for the current Home level, cached until the scan or a delete changes them.
async function level(focus) {
  const key = JSON.stringify(focus);
  if (state.homeCache.has(key)) return state.homeCache.get(key);
  let blocks = null;
  if (focus.kind === "overview") {
    const cats = await categories(false);
    blocks = cats && cats.filter((c) => c.size > 0).map((c) => {
      const meta = CATS[c.id];
      const b = { id: "cat:" + c.id, name: meta.title, size: c.size, color: meta.color, light: meta.light, note: meta.help,
        target: c.raw.length ? { kind: "cat", id: c.id } : null };
      if (c.raw.length) b.children = shade(group(c.raw.map(toBlock), c.size, 10, 0.03, b.id), b);
      return b;
    }).sort((a, b) => b.size - a.size);
  } else if (focus.kind === "cat") {
    const c = (await categories(true))?.find((x) => x.id === focus.id);
    blocks = c && nest(group(c.raw.map(toBlock), c.size, 24, 0.004, focus.id));
  } else {
    const entries = await kids(focus.path, true);
    blocks = entries && nest(group(entries.map(toBlock), entries.reduce((s, e) => s + e.size, 0), 24, 0.004, focus.path));
  }
  if (blocks) state.homeCache.set(key, blocks);
  return blocks;
}

const homeIsDisk = () => isDriveRoot(state.scan.sum?.root || "");
const homeDefault = () => (homeIsDisk() ? { kind: "overview" } : { kind: "node", path: state.scan.sum.root });

function crumbs(focus) {
  const root = state.scan.sum.root;
  const disk = homeIsDisk();
  const out = [{ title: disk ? state.vol?.name || root : root, focus: null }];
  if (focus.kind === "cat") out.push({ title: CATS[focus.id].title, focus });
  if (focus.kind !== "node" || samePath(focus.path, root)) return out;
  const parts = focus.path.slice(root.replace(/\\$/, "").length + 1).split("\\");
  let chain = parts.map((_, i) => root.replace(/\\$/, "") + "\\" + parts.slice(0, i + 1).join("\\"));
  if (disk) {
    const first = parts[0].toLowerCase();
    const cat = first === "users" ? "users" : /^program files( \(x86\))?$/.test(first) ? "apps" : "system";
    out.push({ title: CATS[cat].title, focus: { kind: "cat", id: cat } });
    if (cat !== "system") chain = chain.slice(1);
    // the users category already shows what is in the home folder
    if (cat === "users" && chain.length > 1 && samePath(chain[0], state.home)) chain = chain.slice(1);
  }
  return out.concat(chain.map((p) => ({ title: baseName(p), focus: { kind: "node", path: p } })));
}

function statCard(title, value, detail, highlight, action) {
  const c = h(`<div class="card${highlight ? " hl" : ""}${action ? " click" : ""}"><small>${esc(title)}</small><b>${esc(value)}</b><span>${esc(detail)}</span></div>`);
  if (action) c.onclick = action;
  return c;
}

function homeHeader(focus) {
  const v = state.vol;
  const used = v ? v.total - v.free : 0;
  const head = h(`<div class="crumbs"></div>`);
  const cs = state.scan.phase === "done" ? crumbs(focus) : [{ title: v?.name || drive(), focus: null }];
  if (cs.length > 1) {
    const back = h(`<button class="iconbtn" title="${L("Back", "Kembali")}">${svg("back", "")}</button>`);
    back.onclick = () => { state.homeFocus = cs[cs.length - 2].focus; repaint(); };
    head.append(back);
  }
  cs.forEach((c, i) => {
    if (i) head.append(h(`<span class="sep">›</span>`));
    const b = h(`<button class="crumb${i === cs.length - 1 ? " on" : ""}">${esc(c.title)}</button>`);
    b.onclick = () => { state.homeFocus = c.focus; repaint(); };
    head.append(b);
  });
  head.append(h(`<span class="grow"></span>`), h(`<span class="vol">${v ? L(`${fmt(used)} of ${fmt(v.total)}`, `${fmt(used)} dari ${fmt(v.total)}`) : ""}</span>`));

  const cards = h(`<div class="cards"></div>`);
  const frac = v && v.total ? used / v.total : 0;
  cards.append(statCard(L("Free Space", "Ruang kosong"), v ? fmt(v.free) : "—", L(`${nf1.format(frac * 100)}% used`, `${nf1.format(frac * 100)}% terpakai`)));
  if (state.junkPhase === "done") {
    cards.append(statCard(L("Cleanable", "Bisa dibersihkan"), "± " + fmt(junkSelectedSize()), L("View junk ›", "Lihat sampah ›"), true, () => show("cleanup")));
  } else if (state.junkPhase === "scanning") {
    cards.append(statCard(L("Cleanable", "Bisa dibersihkan"), "…", L("Scanning for junk…", "Memindai sampah…"), true, () => show("cleanup")));
  } else {
    cards.append(statCard(L("Cleanable", "Bisa dibersihkan"), "—", L("Scan for junk ›", "Pindai sampah ›"), true, () => {
      show("cleanup");
      if (state.junkPhase === "idle") startJunk();
    }));
  }
  if (state.files) {
    const ls = largeStats();
    cards.append(statCard(L("Large Files", "File besar"), L(ls.count === 1 ? "1 file" : `${ls.count} files`, `${ls.count} file`),
      L(`${fmt(ls.size)} · view list ›`, `${fmt(ls.size)} · lihat daftar ›`), false, () => show("large")));
  } else {
    cards.append(statCard(L("Large Files", "File besar"), "—", L("Scan the disk first", "Pindai disk dulu")));
  }
  const wrap = h(`<div class="home-head"></div>`);
  wrap.append(head, cards);
  return wrap;
}

/// What can't be removed from Home: drives, the profile folders themselves,
/// and anything Windows or an installed program owns.
function isProtected(p) {
  const d = drive().toLowerCase();
  const l = p.toLowerCase().replace(/\\+$/, "");
  if (isDriveRoot(p)) return true;
  const home = state.home.toLowerCase();
  if ([d + "users", home, home + "\\appdata", home + "\\appdata\\local", home + "\\appdata\\roaming", home + "\\appdata\\locallow"].includes(l)) return true;
  if (inside(l, d + "users") && !inside(l, home)) return true;
  const sys = ["windows", "program files", "program files (x86)", "programdata", "$recycle.bin", "system volume information", "recovery", "boot"];
  if (sys.some((s) => l === d + s || inside(l, d + s))) return true;
  return /^[a-z]:\\(pagefile|hiberfil|swapfile)\.sys$/.test(l);
}
const markable = (b) => !!b.path && !isProtected(b.path);
function toggleMark(b) {
  if (!markable(b)) return;
  if (state.marks.has(b.path)) state.marks.delete(b.path);
  else {
    // a folder includes everything inside it
    for (const p of [...state.marks.keys()]) if (inside(p, b.path)) state.marks.delete(p);
    state.marks.set(b.path, { name: b.name, size: b.size });
  }
}
/// Marked items, leaving out anything inside a marked folder.
function collected() {
  const keys = [...state.marks.keys()];
  return keys.filter((p) => !keys.some((q) => q !== p && inside(p, q)))
    .map((p) => ({ path: p, ...state.marks.get(p) }))
    .sort((a, b) => b.size - a.size);
}

async function home() {
  const g = state.gen;
  const focus = state.scan.phase === "done" ? state.homeFocus || homeDefault() : { kind: "overview" };
  $("hero").replaceChildren(homeHeader(focus));
  $("hero").classList.add("flush");
  if (!gate(true)) return;
  $("content").innerHTML = loading(L("Building map…", "Menyusun peta…"));
  collectBar();
  let blocks = await level(focus);
  if (g !== state.gen) return;
  if (!blocks) { // the folder is gone from the scan: back to the top
    state.homeFocus = null;
    blocks = await level(homeDefault());
    if (g !== state.gen || !blocks) return;
    $("hero").replaceChildren(homeHeader(homeDefault()));
  }
  drawMap(blocks, state.homeFocus || homeDefault());
}

function blockEl(b, cls) {
  const el = h(`<div class="${cls}${b.light ? " light" : ""}${state.marks.has(b.path) ? " marked" : ""}${b.target ? " openable" : ""}"></div>`);
  el.style.background = b.color || "#c8c8c8";
  if (b.shade) el.style.backgroundImage = `linear-gradient(rgba(255,255,255,${b.shade}),rgba(255,255,255,${b.shade}))`;
  el.title = b.note ? `${b.name} · ${fmt(b.size)}\n${b.note}` : b.path ? `${b.path}\n${fmt(b.size)}`
    : `${b.name} · ${fmt(b.size)}\n${L("Small files and folders grouped together", "File dan folder kecil yang digabung")}`;
  el.onclick = (e) => { e.stopPropagation(); if (markable(b)) { toggleMark(b); repaint(); } };
  el.ondblclick = (e) => { e.stopPropagation(); if (b.target) { state.homeFocus = b.target; repaint(); } };
  return el;
}

function drawMap(blocks, focus) {
  const map = h(`<div class="map"><div class="tm"></div><div class="side"></div></div>`);
  const tm = map.querySelector(".tm");
  const layout = () => {
    const W = tm.clientWidth, H = tm.clientHeight;
    tm.replaceChildren();
    const rects = squarify(blocks.map((b) => b.size), 0, 0, W, H);
    blocks.forEach((b, i) => {
      const r = rects[i];
      const w = r.w - 6, hh = r.h - 6;
      if (w <= 2 || hh <= 2) return;
      const el = blockEl(b, "blk");
      Object.assign(el.style, { left: `${r.x + 3}px`, top: `${r.y + 3}px`, width: `${w}px`, height: `${hh}px` });
      const head = w >= 56 && hh >= 30;
      const headH = head ? 28 : 0;
      if (head) el.append(h(`<div class="bh"><b>${esc(b.name)}</b>${w > 130 ? `<span>${fmt(b.size)}</span>` : ""}</div>`));
      const iw = w - 12, ih = hh - headH - 6;
      const ks = iw > 24 && ih > 20 ? b.children || [] : [];
      if (!ks.length && head && w <= 130 && hh > 46) el.append(h(`<div class="bs">${fmt(b.size)}</div>`));
      const kr = squarify(ks.map((k) => k.size), 6, headH, iw, ih);
      ks.forEach((k, j) => {
        const q = kr[j];
        if (q.w - 3 <= 2 || q.h - 3 <= 2) return;
        const kel = blockEl(k, "kid");
        Object.assign(kel.style, { left: `${q.x + 1.5}px`, top: `${q.y + 1.5}px`, width: `${q.w - 3}px`, height: `${q.h - 3}px` });
        if (q.w >= 50 && q.h >= 34) kel.append(h(`<div class="kt"><b>${esc(k.name)}</b><span>${fmt(k.size)}</span></div>`));
        el.append(kel);
      });
      tm.append(el);
    });
  };

  // side panel: what this level is, then every block as a row
  const side = map.querySelector(".side");
  const v = state.vol;
  const total = focus.kind === "overview" && v ? v.total - v.free : blocks.reduce((s, b) => s + b.size, 0);
  const kind = { overview: L("Disk", "Disk"), cat: L("Category", "Kategori"), node: L("Folder", "Folder") }[focus.kind];
  const title = focus.kind === "overview" ? v?.name || drive() : focus.kind === "cat" ? CATS[focus.id].title : baseName(focus.path);
  const path = focus.kind === "overview" ? state.scan.sum.root : focus.kind === "cat" ? CATS[focus.id].help : focus.path;
  side.append(h(`<div class="side-head"><small>${esc(kind)}</small><b>${esc(title)}</b><span class="p">${esc(path)}</span>
    <div class="side-size"><strong>${fmt(total)}</strong><span>${L(`${blocks.length} items`, `${blocks.length} item`)}</span></div></div>`));
  const list = h(`<div class="side-list"></div>`);
  const max = Math.max(1, ...blocks.map((b) => b.size));
  for (const b of blocks) {
    const row = h(`<div class="srow">
      <input type="checkbox" class="cb">
      <i class="dot"></i>
      <div class="txt"><b>${esc(b.name)}</b><div class="usebar"><div style="width:${(b.size / max) * 100}%"></div></div></div>
      <span class="size">${fmt(b.size)}</span>
      ${b.target ? `<button class="iconbtn" title="${L("Open", "Buka")}">${svg("chev", "")}</button>` : '<span style="width:22px"></span>'}
    </div>`);
    row.querySelector(".dot").style.background = b.color || "#c8c8c8";
    const cb = row.querySelector(".cb");
    cb.checked = state.marks.has(b.path);
    cb.disabled = !markable(b);
    cb.title = markable(b) ? L("Collect", "Kumpulkan") : L("Can't be deleted from here", "Tidak bisa dihapus dari sini");
    cb.onclick = () => { toggleMark(b); repaint(); };
    const open = row.querySelector(".iconbtn");
    if (open) open.onclick = () => { state.homeFocus = b.target; repaint(); };
    row.ondblclick = () => { if (b.target) { state.homeFocus = b.target; repaint(); } };
    list.append(row);
  }
  side.append(list);

  $("content").classList.add("flush");
  $("content").replaceChildren(...partialBanner(), map);
  layout();
  new ResizeObserver(() => layout()).observe(tm);
}

function collectBar() {
  const items = collected();
  const total = items.reduce((s, i) => s + i.size, 0);
  const more = items.length - 3;
  const left = h(`<div class="collect">
    <span class="n${items.length ? " on" : ""}">${items.length}</span>
    <div><b>${L(`${total ? fmt(total) : "0 MB"} collected`, `${total ? fmt(total) : "0 MB"} dikumpulkan`)}</b>
    <small>${esc(items.length
      ? items.slice(0, 3).map((i) => i.name).join(", ") + (more > 0 ? L(` and ${more} more`, ` dan ${more} lainnya`) : "")
      : L("Click files in the chart or check items in the list to collect them. Double-click to open a folder.",
        "Klik file di grafik atau centang item di daftar untuk mengumpulkannya. Klik dua kali untuk membuka folder."))}</small></div>
  </div>`);
  setFooter([left], [
    button(L("Show in Explorer", "Tampilkan di Explorer"), () => invoke("reveal", { paths: items.map((i) => i.path) }), false, !items.length),
    button(L("Clear", "Kosongkan"), () => { state.marks.clear(); repaint(); }, false, !items.length),
    button(L("Move to Recycle Bin…", "Pindahkan ke Recycle Bin…"), async () => {
      if (!confirm(L(`Move ${items.length} item(s) (${fmt(total)}) to the Recycle Bin?`, `Pindahkan ${items.length} item (${fmt(total)}) ke Recycle Bin?`))) return;
      await trash(items.map((i) => i.path));
    }, true, !items.length),
  ]);
}

/// Recycle Bin for any analysis tool; the backend also drops the items from the scan.
async function trash(paths) {
  const failed = await invoke("trash_paths", { paths }).catch(() => paths);
  const done = new Set(paths.filter((p) => !failed.includes(p)));
  const gone = (p) => done.has(p) || [...done].some((d) => inside(p, d));
  if (state.files) state.files = state.files.filter((f) => !gone(f.path));
  state.dupe.groups = state.dupe.groups
    .map((g) => ({ ...g, items: g.items.filter((f) => !gone(f.path)) }))
    .filter((g) => g.items.length > 1)
    .map((g) => ({ ...g, wasted: g.size * (g.items.length - 1) }));
  for (const p of done) state.marks.delete(p);
  state.homeCache.clear();
  state.usageCache = null;
  state.sel.clear();
  state.hl.clear();
  toast(L(`${done.size} moved to the Recycle Bin`, `${done.size} dipindahkan ke Recycle Bin`) +
    (failed.length ? L(` · ${failed.length} failed`, ` · ${failed.length} gagal`) : ""));
  updateBadges();
  refreshDisk();
  repaint();
}

// ---------- file kinds ----------
const KIND_EXT = {
  video: "mp4 mkv avi mov wmv flv webm m4v mpg mpeg mts",
  archive: "zip rar 7z tar gz tgz bz2 xz zst cab msi msix appx",
  disk: "iso img vmdk vdi vhd vhdx qcow2 wim raw hdd",
  image: "jpg jpeg png heic gif tif tiff psd cr2 cr3 nef arw dng webp bmp",
  audio: "mp3 wav aif aiff flac m4a aac ogg wma",
  document: "pdf doc docx xls xlsx ppt pptx odt ods epub",
};
const KIND = {
  folder: { label: "Folder", color: "var(--accent-text)" },
  video: { label: "Video", color: "#9b59b6" },
  archive: { label: L("Archives & Installers", "Arsip & Installer"), color: "#e67e22" },
  disk: { label: "Disk Image", color: "#3b82f6" },
  image: { label: L("Images", "Gambar"), color: "#ec4899" },
  audio: { label: "Audio", color: "#ef4444" },
  document: { label: L("Documents", "Dokumen"), color: "#a16207" },
  other: { label: L("Other", "Lainnya"), color: "#8e8e93" },
};
const EXT_KIND = {};
for (const [k, list] of Object.entries(KIND_EXT)) for (const e of list.split(" ")) EXT_KIND[e] = k;
const extOf = (name) => {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(i + 1).toLowerCase() : "";
};
const kindOf = (it) => (it.kind ??= it.isDir ? "folder" : EXT_KIND[extOf(it.name)] || "other");
const badgeOf = (it) => (it.isDir ? "DIR" : extOf(it.name).slice(0, 4).toUpperCase() || "FILE");

// ---------- sorting and dates ----------
const coll = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
const FIRST_DIR = { name: "asc", modified: "desc", size: "desc" };
function sortItems(items, s) {
  const d = s.dir === "asc" ? 1 : -1;
  const by = s.key === "name" ? (a, b) => coll.compare(a.name, b.name)
    : s.key === "modified" ? (a, b) => a.modified - b.modified
    : (a, b) => a.size - b.size;
  return items.slice().sort((a, b) => by(a, b) * d || coll.compare(a.name, b.name));
}
const rtf = new Intl.RelativeTimeFormat(ID ? "id" : "en", { numeric: "auto" });
function fmtRel(s) {
  if (!s) return "";
  const days = Math.max(0, Math.round((Date.now() / 1000 - s) / 86400));
  if (days < 30) return rtf.format(-days, "day");
  if (days < 365) return rtf.format(-Math.round(days / 30), "month");
  return rtf.format(-Math.round(days / 365), "year");
}

// ---------- toolbar pieces ----------
function searchBox(value, onInput, placeholder) {
  const i = h(`<input class="field search" type="search" spellcheck="false" placeholder="${esc(placeholder)}">`);
  i.value = value;
  i.oninput = () => onInput(i.value);
  return i;
}
function segmented(options, current, onPick) {
  const seg = h(`<div class="seg"></div>`);
  for (const [v, t] of options) {
    const b = h(`<button${v === current ? ' class="on"' : ""}>${esc(t)}</button>`);
    b.onclick = () => {
      seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === b));
      onPick(v);
    };
    seg.append(b);
  }
  return seg;
}
function toolbarEl(controls) {
  const bar = h(`<div class="toolbar"></div>`);
  bar.append(...controls, h(`<span class="grow"></span>`), ...scanTools());
  return bar;
}
const bigEl = () => h(`<div class="big"><b>…</b><span></span></div>`);
function setBig(big, size, text) {
  big.innerHTML = `<b>${fmt(size)}</b><span>${esc(text)}</span>`;
}
/// Chips that redraw themselves; `onPick(value)` runs after the new one is set.
function chipGroup(options, current, onPick) {
  const wrap = h(`<span class="chips-inline"></span>`);
  const draw = () => wrap.replaceChildren(...options.map(([v, t]) => chip(t, v === current, () => { current = v; draw(); onPick(v); })));
  draw();
  return wrap;
}

// ---------- context menu ----------
function ctxMenu(x, y, entries) {
  document.querySelector(".ctx")?.remove();
  const m = h(`<div class="menu ctx"></div>`);
  for (const e of entries) {
    if (e === "-") { m.append(h(`<hr>`)); continue; }
    const b = h(`<button${e.danger ? ' class="danger"' : ""}>${esc(e.label)}</button>`);
    b.onclick = () => { m.remove(); e.run(); };
    m.append(b);
  }
  document.body.append(m);
  const r = m.getBoundingClientRect();
  m.style.left = `${Math.max(4, Math.min(x, innerWidth - r.width - 8))}px`;
  m.style.top = `${Math.max(4, Math.min(y, innerHeight - r.height - 8))}px`;
  setTimeout(() => {
    document.addEventListener("mousedown", (ev) => { if (!m.contains(ev.target)) m.remove(); }, { once: true });
    document.addEventListener("keydown", () => m.remove(), { once: true });
  }, 0);
}

// ---------- selection bar ----------
function selFooter() {
  const vis = state.visible;
  const can = vis.filter((i) => !isProtected(i.path));
  const chosen = vis.filter((i) => state.sel.has(i.path));
  const total = chosen.reduce((s, i) => s + i.size, 0);
  const all = can.length > 0 && can.every((i) => state.sel.has(i.path));
  const left = h(`<div class="selinfo"><span>${L(`${chosen.length} selected`, `${chosen.length} dipilih`)}</span></div>`);
  if (chosen.length) left.append(h(`<span class="dim">${fmt(total)}</span>`));
  const link = h(`<button class="link"${can.length ? "" : " disabled"}>${all ? L("Deselect All", "Batal Pilih Semua") : L("Select All", "Pilih Semua")}</button>`);
  link.onclick = () => {
    for (const i of can) all ? state.sel.delete(i.path) : state.sel.add(i.path);
    state.paint?.();
    selFooter();
  };
  left.append(link);
  const paths = chosen.map((i) => i.path);
  setFooter([left], [
    button(L("Show in Explorer", "Tampilkan di Explorer"), () => invoke("reveal", { paths }), false, !chosen.length),
    button(L("Move to Recycle Bin…", "Pindahkan ke Recycle Bin…"), () => recycle(paths), true, !chosen.length),
  ]);
}
async function recycle(paths) {
  if (!paths.length || !confirm(L(`Move ${paths.length} item(s) to the Recycle Bin?`, `Pindahkan ${paths.length} item ke Recycle Bin?`))) return;
  await trash(paths);
}

// ---------- sortable table (Name / Modified / Size, like ItemTable on macOS) ----------
const ROW_H = 52, HEAD_H = 34, OVERSCAN = 600;

/// Draws `entries` (items, or `{ head: group }` separators) into #content.
/// Only the rows in view exist in the DOM, so a folder with 100k files stays fast.
/// Options: tab (sort key), sortable, relative (second line with "2 years ago"),
/// banners, empty (text), onSort, onOpen(item) for double-clicking a folder.
function renderTable(o) {
  const content = $("content");
  content.onscroll = null;
  state.ro?.disconnect();
  const rows = o.entries;
  const items = rows.filter((r) => !r.head);
  state.visible = items;
  const banners = o.banners || [];
  content.classList.add("tight");
  if (!items.length) {
    state.paint = null;
    content.replaceChildren(...banners, h(`<div class="empty">${esc(o.empty || "")}</div>`));
    return;
  }

  const offs = [0];
  for (const r of rows) offs.push(offs[offs.length - 1] + (r.head ? HEAD_H : ROW_H));
  let maxSize = 1;
  for (const it of items) if (it.size > maxSize) maxSize = it.size;
  const idx = new Map(items.map((it, i) => [it.path, i]));
  const byPath = new Map(items.map((it) => [it.path, it]));

  const wrap = h(`<div class="table${o.relative ? " rel" : ""}" tabindex="0"></div>`);
  if (o.sortable !== false) wrap.append(headerEl(o));
  const body = h(`<div class="tbody"></div>`);
  body.style.height = `${offs[rows.length]}px`;
  wrap.append(body);
  const scroll = content.scrollTop;
  content.replaceChildren(...banners, wrap);
  content.scrollTop = scroll;

  const checkMany = (paths, on) => {
    for (const p of paths) if (!isProtected(p)) on ? state.sel.add(p) : state.sel.delete(p);
    paint();
    selFooter();
  };
  const openItem = (it) => (it.isDir && o.onOpen ? o.onOpen(it) : invoke("reveal", { paths: [it.path] }));

  const select = (it, e) => {
    const k = idx.get(it.path);
    if (e.shiftKey && state.anchor >= 0) {
      const [a, b] = [state.anchor, k].sort((x, y) => x - y);
      state.hl = new Set(items.slice(a, b + 1).map((x) => x.path));
    } else if (e.ctrlKey || e.metaKey) {
      state.hl.has(it.path) ? state.hl.delete(it.path) : state.hl.add(it.path);
      state.anchor = k;
    } else {
      state.hl = new Set([it.path]);
      state.anchor = k;
    }
    paint();
  };

  const menuFor = (it, e) => {
    if (!state.hl.has(it.path)) { state.hl = new Set([it.path]); state.anchor = idx.get(it.path); paint(); }
    const paths = [...state.hl];
    const picked = paths.map((p) => byPath.get(p)).filter(Boolean);
    const entries = [];
    if (picked.length === 1 && picked[0].isDir && o.onOpen) entries.push({ label: L("Open Folder", "Buka Folder"), run: () => o.onOpen(picked[0]) });
    entries.push(
      { label: L("Show in Explorer", "Tampilkan di Explorer"), run: () => invoke("reveal", { paths }) },
      "-",
      { label: L("Check", "Centang"), run: () => checkMany(paths, true) },
      { label: L("Uncheck", "Hapus Centang"), run: () => checkMany(paths, false) },
      "-",
      { label: L("Move to Recycle Bin…", "Pindahkan ke Recycle Bin…"), danger: true, run: () => recycle(paths.filter((p) => !isProtected(p))) },
    );
    ctxMenu(e.clientX, e.clientY, entries);
  };

  const itemRow = (it) => {
    const k = KIND[kindOf(it)];
    const protectedPath = isProtected(it.path);
    const el = h(`<div class="trow${state.hl.has(it.path) ? " hl" : ""}">
      <input type="checkbox" class="cb">
      <div class="tname">
        <span class="badge" style="--k:${k.color}">${esc(badgeOf(it))}</span>
        <div class="tt"><b>${esc(it.name)}</b><small>${esc(parent(it.path))}</small></div>
        ${it.keep ? `<span class="keep">${L("Oldest", "Terlama")}</span>` : ""}
      </div>
      <div class="tmod"><span>${esc(fmtDate(it.modified) || "—")}</span>${o.relative ? `<small>${esc(fmtRel(it.modified))}</small>` : ""}</div>
      <div class="tsize"><b>${fmt(it.size)}</b><i><u style="width:${((it.size / maxSize) * 100).toFixed(1)}%"></u></i></div>
    </div>`);
    const cb = el.querySelector(".cb");
    cb.checked = state.sel.has(it.path);
    cb.disabled = protectedPath;
    if (protectedPath) cb.title = L("Can't be deleted from here", "Tidak bisa dihapus dari sini");
    cb.onclick = (ev) => {
      ev.stopPropagation();
      cb.checked ? state.sel.add(it.path) : state.sel.delete(it.path);
      selFooter();
    };
    el.onclick = (ev) => {
      if (ev.target === cb) return;
      wrap.focus({ preventScroll: true });
      select(it, ev);
    };
    el.ondblclick = (ev) => { if (ev.target !== cb) openItem(it); };
    el.oncontextmenu = (ev) => { ev.preventDefault(); menuFor(it, ev); };
    return el;
  };

  const at = (y) => { // first row whose bottom edge is below y
    let lo = 0, hi = rows.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (offs[mid + 1] <= y) lo = mid + 1; else hi = mid;
    }
    return lo;
  };
  let raf = 0;
  function paint() {
    raf = 0;
    const y = content.getBoundingClientRect().top - body.getBoundingClientRect().top;
    const bottom = y + content.clientHeight + OVERSCAN;
    const els = [];
    for (let i = at(Math.max(0, y - OVERSCAN)); i < rows.length && offs[i] < bottom; i++) {
      const r = rows[i];
      const el = r.head
        ? h(`<div class="trow ghead"><span>${L(`${r.head.items.length} copies`, `${r.head.items.length} salinan`)}</span><span>${fmt(r.head.size)} ${L("each", "per file")}</span></div>`)
        : itemRow(r);
      el.style.top = `${offs[i]}px`;
      el.style.height = `${offs[i + 1] - offs[i]}px`;
      els.push(el);
    }
    body.replaceChildren(...els);
  }
  const schedule = () => { if (!raf) raf = requestAnimationFrame(paint); };
  content.onscroll = schedule;
  state.ro = new ResizeObserver(schedule);
  state.ro.observe(content);
  state.paint = paint;

  wrap.onkeydown = (e) => {
    if (e.key !== " " || !state.hl.size) return;
    e.preventDefault();
    const paths = [...state.hl].filter((p) => !isProtected(p));
    checkMany(paths, !paths.every((p) => state.sel.has(p)));
  };
  paint();
}

function headerEl(o) {
  const s = state.sort[o.tab];
  const hd = h(`<div class="thead"></div>`);
  hd.append(h(`<span></span>`));
  for (const [key, title] of [["name", L("Name", "Nama")], ["modified", L("Modified", "Diubah")], ["size", L("Size", "Ukuran")]]) {
    const on = s.key === key;
    const c = h(`<button class="th ${key}${on ? " on" : ""}" title="${L("Sort by", "Urutkan berdasarkan")} ${esc(title)}">${esc(title)}${on ? `<em>${s.dir === "asc" ? "▲" : "▼"}</em>` : ""}</button>`);
    c.onclick = () => {
      state.sort[o.tab] = on ? { key, dir: s.dir === "asc" ? "desc" : "asc" } : { key, dir: FIRST_DIR[key] };
      $("content").scrollTop = 0;
      o.onSort();
    };
    hd.append(c);
  }
  return hd;
}

// ---------- Disk Usage ----------
function chainOf(root, path) {
  const out = [{ title: root, path: root }];
  if (samePath(path, root)) return out;
  const r = root.replace(/[\\/]+$/, "");
  const parts = path.slice(r.length + 1).split("\\");
  parts.forEach((t, i) => out.push({ title: t, path: r + "\\" + parts.slice(0, i + 1).join("\\") }));
  return out;
}
function openUsage(path) {
  state.usagePath = samePath(path, state.scan.sum.root) ? null : path;
  state.sel.clear();
  state.hl.clear();
  state.anchor = -1;
  repaint();
}

async function usage() {
  if (!gate()) return;
  const g = state.gen;
  const root = state.scan.sum.root;
  const path = state.usagePath || root;
  const chain = chainOf(root, path);

  const back = h(`<button class="btn tool" title="${L("Back", "Kembali")}">${svg("back", "")}</button>`);
  back.disabled = chain.length < 2;
  back.onclick = () => openUsage(chain[chain.length - 2].path);
  const crumbs = h(`<div class="crumbscroll"></div>`);
  chain.forEach((c, i) => {
    if (i) crumbs.append(h(`<span class="sep">›</span>`));
    const b = h(`<button class="crumb${i === chain.length - 1 ? " on" : ""}">${esc(c.title)}</button>`);
    b.onclick = () => openUsage(c.path);
    crumbs.append(b);
  });
  const big = bigEl();
  big.style.marginTop = "12px";
  const bar = toolbarEl([back, crumbs]);
  bar.style.marginTop = "0";
  $("hero").replaceChildren(bar, big);
  requestAnimationFrame(() => (crumbs.scrollLeft = crumbs.scrollWidth));

  let data = state.usageCache?.path === path ? state.usageCache : null;
  if (!data) {
    setFooter([], []);
    $("content").innerHTML = loading(L("Reading folder…", "Membaca folder…"));
    const [kids, info] = await Promise.all([
      invoke("tree_children", { path }).catch((e) => ({ error: String(e) })),
      invoke("tree_info", { path }).catch(() => null),
    ]);
    if (g !== state.gen) return;
    if (kids.error) { state.usagePath = null; $("content").innerHTML = `<div class="empty">${esc(kids.error)}</div>`; return; }
    data = state.usageCache = { path, items: kids.map((e) => ({ ...e, isDir: e.is_dir })), info };
  }

  const size = data.info?.size ?? data.items.reduce((s, e) => s + e.size, 0);
  const pct = data.info?.parent_size ? (size / data.info.parent_size) * 100 : null;
  big.innerHTML = `<b>${fmt(size)}</b>` +
    (pct != null ? `<span>${L(`${nf1.format(pct)}% of parent folder`, `${nf1.format(pct)}% dari folder induk`)}</span>` : "") +
    `<span class="grow"></span>` +
    (data.info?.modified ? `<small>${L("Last modified", "Terakhir berubah")} ${esc(fmtRel(data.info.modified))}</small>` : "");

  const draw = () => {
    renderTable({
      tab: "usage", entries: sortItems(data.items, state.sort.usage), banners: partialBanner(),
      onSort: draw, onOpen: (it) => openUsage(it.path),
      empty: L("This folder is empty.", "Folder ini kosong."),
    });
    selFooter();
  };
  draw();
}

// ---------- Large files ----------
function large() {
  if (!gate()) return;
  const f = state.f.large;
  const needle = () => f.q.trim().toLowerCase();
  const big = bigEl();
  const draw = () => {
    const q = needle();
    const rows = state.files.filter((x) => x.size >= f.min && (!f.kind || kindOf(x) === f.kind) && (!q || x.name.toLowerCase().includes(q)));
    setBig(big, rows.reduce((s, x) => s + x.size, 0), L(`in ${count(rows.length)} ${rows.length === 1 ? "file" : "files"}`, `dalam ${count(rows.length)} file`));
    renderTable({
      tab: "large", entries: sortItems(rows, state.sort.large), banners: partialBanner(), onSort: draw,
      empty: L("No files match this filter.", "Tidak ada file yang cocok dengan filter ini."),
    });
    selFooter();
  };
  const redraw = () => { $("content").scrollTop = 0; draw(); };
  const kinds = [[null, L("All", "Semua")], ...["video", "archive", "disk", "image", "audio", "document", "other"].map((k) => [k, KIND[k].label])];
  const chips = h(`<div class="chiprow"></div>`);
  chips.append(chipGroup(kinds, f.kind, (v) => { f.kind = v; redraw(); }));
  $("hero").replaceChildren(big, toolbarEl([
    searchBox(f.q, (v) => { f.q = v; redraw(); }, L("Search file names", "Cari nama file")),
    segmented([[50 << 20, "50 MB"], [100 << 20, "100 MB"], [500 << 20, "500 MB"], [1 << 30, "1 GB"]], f.min, (v) => { f.min = v; redraw(); }),
  ]), chips);
  draw();
}

// ---------- Not modified lately ----------
function stale() {
  if (!gate()) return;
  const f = state.f.stale;
  const big = bigEl();
  const appData = () => state.home + "\\AppData";
  const draw = () => {
    const q = f.q.trim().toLowerCase();
    const cutoff = Date.now() / 1000 - f.age * 30.44 * 86400;
    const rows = state.files.filter((x) => x.modified > 0 && x.modified < cutoff && x.size >= f.min &&
      (!f.skipApp || !inside(x.path, appData())) && (!q || x.name.toLowerCase().includes(q)));
    setBig(big, rows.reduce((s, x) => s + x.size, 0), L(`in ${count(rows.length)} ${rows.length === 1 ? "file" : "files"}`, `dalam ${count(rows.length)} file`));
    renderTable({
      tab: "stale", entries: sortItems(rows, state.sort.stale), banners: partialBanner(), relative: true, onSort: draw,
      empty: L("No long-unmodified files match this filter.", "Tidak ada file yang lama tak berubah dengan filter ini."),
    });
    selFooter();
  };
  const redraw = () => { $("content").scrollTop = 0; draw(); };
  const ages = [[6, L("> 6 months", "> 6 bulan")], [12, L("> 1 year", "> 1 tahun")], [24, L("> 2 years", "> 2 tahun")], [36, L("> 3 years", "> 3 tahun")], [60, L("> 5 years", "> 5 tahun")]];
  const skip = h(`<label class="check"><input type="checkbox" class="cb"> ${L("Skip AppData", "Lewati AppData")}</label>`);
  skip.title = L("AppData holds app data that rarely changes but is still in use", "AppData berisi data aplikasi yang jarang berubah tapi masih dipakai");
  const cb = skip.querySelector("input");
  cb.checked = f.skipApp;
  cb.onchange = () => { f.skipApp = cb.checked; redraw(); };
  const chips = h(`<div class="chiprow"><span class="lbl">${L("Not modified", "Tidak diubah")}</span></div>`);
  chips.append(chipGroup(ages, f.age, (v) => { f.age = v; redraw(); }), skip);
  $("hero").replaceChildren(big, toolbarEl([
    searchBox(f.q, (v) => { f.q = v; redraw(); }, L("Search names", "Cari nama")),
    segmented([[1 << 20, "≥ 1 MB"], [10 << 20, "≥ 10 MB"], [100 << 20, "≥ 100 MB"], [1 << 30, "≥ 1 GB"]], f.min, (v) => { f.min = v; redraw(); }),
  ]), chips);
  draw();
}

// ---------- Duplicates ----------
async function startDupes() {
  const d = state.dupe;
  if (d.phase === "scanning") return;
  d.phase = "scanning";
  d.progress = null;
  repaintFor("dupes");
  const stop = poll("dupes", (p) => { d.progress = p; repaintFor("dupes", true); });
  const r = await invoke("find_dupes", { root: state.scan.sum.root, skipProtected: d.skip }).catch((e) => ({ error: String(e) }));
  stop();
  if (state.dupe !== d) return; // a new analysis started meanwhile
  if (r.error) { d.phase = "idle"; toast(r.error); } else { d.groups = r.groups; d.partial = r.partial; d.phase = "done"; }
  updateBadges();
  repaintFor("dupes");
}

function dupes() {
  if (!gate()) return;
  const d = state.dupe;
  if (d.phase === "idle") {
    const n = state.files.length;
    const skip = h(`<label class="check"><input type="checkbox" class="cb"> ${L("Skip Windows, Program Files, AppData, and node_modules / .git folders", "Lewati Windows, Program Files, AppData, dan folder node_modules / .git")}</label>`);
    const cb = skip.querySelector("input");
    cb.checked = d.skip;
    cb.onchange = () => (d.skip = cb.checked);
    skip.title = L("Files inside are often duplicated on purpose; deleting them can break apps", "File di dalamnya sering sengaja kembar; menghapusnya bisa merusak aplikasi");
    return showPanel(panel({
      ring: svg("copy", "big-ic"),
      title: L("Find Duplicate Files", "Cari file duplikat"),
      text: L(`CleanBro compares the contents of ${n === 1 ? "1 file" : `${count(n)} files`} of 1 MB or larger in ${state.scan.sum.root}. Only files of the same size are read, and their contents are matched byte by byte using SHA-256.`,
        `CleanBro membandingkan isi ${count(n)} file berukuran ≥ 1 MB di ${state.scan.sum.root}. Hanya file dengan ukuran sama yang dibaca, dan isinya dicocokkan byte demi byte lewat SHA-256.`),
      extra: [skip],
      actions: [button(L("Find Duplicates", "Cari Duplikat"), startDupes, true)],
    }));
  }
  if (d.phase === "scanning") {
    const p = d.progress;
    const frac = p && p.total ? p.done / p.total : 0;
    $("hero").innerHTML = "";
    setFooter([], []);
    return scanningView("dupes", {
      big: `${Math.floor(frac * 100)}%`, frac,
      line: p ? L(`${count(p.done)} of ${p.total === 1 ? "1 file" : `${count(p.total)} files`} checked · ${fmt(p.bytes)} read`, `${count(p.done)} dari ${count(p.total)} file dicek · ${fmt(p.bytes)} dibaca`) : "",
      current: p?.current, stopping: p?.stopping,
      onStop: () => invoke("cancel_job", { kind: "dupes" }),
    });
  }
  const f = state.f.dupes;
  const big = bigEl();
  const draw = () => {
    const q = f.q.trim().toLowerCase();
    const groups = d.groups.filter((g) => g.size >= d.min && (!q || g.items.some((x) => x.name.toLowerCase().includes(q))));
    setBig(big, groups.reduce((s, x) => s + x.wasted, 0), L(`can be freed · ${count(groups.length)} ${groups.length === 1 ? "group" : "groups"}`, `bisa dihemat · ${count(groups.length)} grup`));
    const entries = [];
    for (const g of groups) {
      entries.push({ head: g });
      g.items.forEach((x, i) => { x.keep = i === 0; entries.push(x); });
    }
    const banners = partialBanner();
    if (d.partial) banners.push(banner(L("Search stopped. This list only contains groups that have finished matching.", "Pencarian dihentikan. Daftar ini hanya berisi grup yang sudah selesai dicocokkan."), startDupes));
    renderTable({
      tab: "dupes", entries, sortable: false, banners,
      empty: d.groups.length ? L("No duplicates match this filter.", "Tidak ada duplikat yang cocok dengan filter ini.") : L("No duplicate files. 🎉", "Tidak ada file duplikat. 🎉"),
    });
    selFooter();
  };
  const redraw = () => { $("content").scrollTop = 0; draw(); };
  $("hero").replaceChildren(big, toolbarEl([
    searchBox(f.q, (v) => { f.q = v; redraw(); }, L("Search file names", "Cari nama file")),
    segmented([[1 << 20, "≥ 1 MB"], [10 << 20, "≥ 10 MB"], [100 << 20, "≥ 100 MB"], [1 << 30, "≥ 1 GB"]], d.min, (v) => { d.min = v; redraw(); }),
    button(L("Search Again", "Cari Ulang"), () => { d.phase = "idle"; repaint(); }),
  ]));
  draw();
}

// ---------- navigation ----------
const VIEWS = { home, cleanup, uninstall, usage, large, stale, dupes };
/// Redraws the open tab in place (progress ticks, phase changes).
function repaint() {
  state.gen++;
  $("hero").classList.remove("flush");
  $("content").classList.remove("flush", "tight");
  $("content").onscroll = null;
  state.ro?.disconnect();
  state.paint = null;
  VIEWS[state.tab]();
  updateBadges();
}
function show(tab, keepNote = false) {
  state.tab = tab;
  if (!keepNote) state.note = "";
  state.sel.clear();
  state.hl.clear();
  state.anchor = -1;
  // the home map is about the whole disk (only when nothing was scanned yet)
  if (tab === "home" && state.scan.phase === "idle" && !state.scan.sum) state.scan.root = drive();
  document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
  $("title").textContent = T[tab];
  $("hero").innerHTML = "";
  $("content").innerHTML = "";
  $("content").scrollTop = 0;
  setFooter([], []);
  if (tab !== "uninstall") state.app = null;
  repaint();
}

(async () => {
  initSidebar();
  state.home = await invoke("home_dir");
  state.scan.root = state.home;
  await refreshDisk();
  // nothing is scanned until the user asks, like the macOS app
  show("home");
})();
