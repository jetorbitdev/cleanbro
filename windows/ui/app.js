const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

// ---------- i18n ----------
const ID = (navigator.language || "").toLowerCase().startsWith("id");
const L = (en, id) => (ID ? id : en);
const T = {
  tools: L("Tools", "Alat"),
  analysis: L("Analysis", "Analisis"),
  cleanup: L("Cleanup", "Pembersihan"),
  usage: L("Disk Usage", "Penggunaan Disk"),
  large: L("Large Files", "File Besar"),
  stale: L("Stale Files", "Lama Tak Diubah"),
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
function summary(names) {
  if (!names.length) return L("Already clean", "Sudah bersih");
  const top = names.slice(0, 3).join(", ");
  const rest = names.length - 3;
  return rest > 0 ? L(`${top}, and ${rest} more`, `${top}, dan ${rest} lainnya`) : top;
}
const loading = (text) => `<div class="loading"><div class="spin"></div>${esc(text)}</div>`;

// ---------- state ----------
const state = {
  tab: "cleanup",
  home: "",
  root: "",
  gen: 0, // bumps on every navigation; late results from an old page are dropped
  junk: null,
  junkSel: new Set(),
  open: new Set(),
  files: null,
  filesRoot: "",
  sel: new Set(),
  sizes: new Map(),
  note: "",
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

// ---------- sidebar ----------
function initSidebar() {
  document.querySelectorAll("[data-l]").forEach((e) => (e.textContent = T[e.dataset.l]));
  document.querySelectorAll("[data-icon]").forEach((e) => (e.innerHTML = svg(e.dataset.icon)));
  document.querySelectorAll(".nav").forEach((b) => (b.onclick = () => show(b.dataset.tab)));
}
async function refreshDisk() {
  const d = await invoke("disk_info", { path: state.home }).catch(() => null);
  if (!d) return;
  $("disk").hidden = false;
  $("disk-name").textContent = d.name;
  $("disk-free").textContent = L(`${fmt(d.free)} free`, `${fmt(d.free)} kosong`);
  $("disk-bar").style.width = `${((d.total - d.free) / d.total) * 100}%`;
  $("disk-used").textContent = L(`${fmt(d.total - d.free)} of ${fmt(d.total)} used`, `${fmt(d.total - d.free)} dari ${fmt(d.total)} terpakai`);
}

// ---------- Cleanup ----------
async function cleanup(rescan = false) {
  const g = state.gen;
  if (!state.junk || rescan) {
    $("hero").innerHTML = "";
    $("content").innerHTML = loading(L("Scanning…", "Memindai…"));
    setFooter([], []);
    const cats = await invoke("scan_junk").catch((e) => ({ error: String(e) }));
    if (g !== state.gen) return;
    if (cats.error) { $("content").innerHTML = `<div class="empty">${esc(cats.error)}</div>`; return; }
    state.junk = cats;
    state.junkSel = new Set(cats.filter((c) => c.id !== "recycle").flatMap((c) => c.items.map((i) => i.path)));
  }
  renderCleanup();
}

function renderCleanup() {
  const cats = state.junk;
  const total = cats.reduce((s, c) => s + c.items.reduce((t, i) => t + i.size, 0), 0);
  const selSize = cats.flatMap((c) => c.items).filter((i) => state.junkSel.has(i.path)).reduce((s, i) => s + i.size, 0);
  $("badge").textContent = total ? fmt(total) : "";
  $("hero").innerHTML = `<div class="big"><b>${fmt(total)}</b><span>${L("can be cleaned", "bisa dibersihkan")}</span></div>`;

  const rows = [];
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
          renderCleanup();
        };
        rows.push(sub);
      }
    }
  }
  const scroll = $("content").scrollTop;
  $("content").replaceChildren(...rows);
  $("content").scrollTop = scroll;

  const note = state.note ? [h(`<span>${esc(state.note)}</span>`)] : [];
  setFooter(
    [button(L("Rescan", "Pindai Ulang"), () => { state.note = ""; cleanup(true); }), ...note],
    [button(selSize ? L(`Clean ${fmt(selSize)}`, `Bersihkan ${fmt(selSize)}`) : L("Clean", "Bersihkan"), runClean, true, !selSize)],
  );
}

async function runClean() {
  const paths = [...state.junkSel];
  if (!paths.length) return;
  if (!confirm(L(`Permanently delete ${paths.length} item(s)? This cannot be undone.`, `Hapus permanen ${paths.length} item? Tindakan ini tidak bisa dibatalkan.`))) return;
  $("content").innerHTML = loading(L("Cleaning…", "Membersihkan…"));
  setFooter([], []);
  const r = await invoke("clean_junk", { paths });
  state.note = L(`Freed ${fmt(r.freed)}`, `${fmt(r.freed)} dibebaskan`) +
    (r.failed.length ? L(` · ${r.failed.length} in use, skipped`, ` · ${r.failed.length} sedang dipakai, dilewati`) : "");
  refreshDisk();
  await cleanup(true);
}

// ---------- analysis: shared toolbar ----------
function toolbar(extra = []) {
  const bar = h(`<div class="toolbar"></div>`);
  const up = h(`<button class="btn" title="${L("Parent folder", "Folder induk")}">${svg("up", "")}</button>`);
  up.style.padding = "0 8px";
  up.firstChild.style.cssText = "width:14px;height:14px";
  const field = h(`<input class="field" spellcheck="false">`);
  field.value = state.root;
  const go = () => { state.root = field.value.trim() || state.home; state.files = null; show(state.tab); };
  up.onclick = () => { field.value = parent(field.value); go(); };
  field.onkeydown = (e) => { if (e.key === "Enter") go(); };
  bar.append(up, field, button(L("Scan", "Pindai"), go), ...extra);
  return bar;
}

async function ensureFiles() {
  if (state.files && state.filesRoot === state.root) return true;
  const g = state.gen;
  $("content").innerHTML = loading(L("Scanning files…", "Memindai file…"));
  const r = await invoke("scan_files", { root: state.root, minBytes: 1 << 20 }).catch((e) => ({ error: String(e) }));
  if (g !== state.gen) return false;
  if (r.error) { $("content").innerHTML = `<div class="empty">${esc(r.error)}</div>`; return false; }
  state.files = r;
  state.filesRoot = state.root;
  return true;
}

function selFooter() {
  const size = [...state.sel].reduce((s, p) => s + (state.sizes.get(p) || 0), 0);
  const left = state.note
    ? [h(`<span>${esc(state.note)}</span>`)]
    : [h(`<span>${state.sel.size ? L(`${state.sel.size} selected · ${fmt(size)}`, `${state.sel.size} dipilih · ${fmt(size)}`) : ""}</span>`)];
  setFooter(left, [button(L("Move to Recycle Bin", "Pindahkan ke Recycle Bin"), moveToBin, false, !state.sel.size)]);
}

function fileRow(f, extra = "") {
  state.sizes.set(f.path, f.size);
  const row = h(`<div class="row click">
    <input type="checkbox" class="cb">
    ${svg("file", "ic")}
    <div class="txt"><b>${esc(f.name)}</b><small>${esc(f.path)}</small></div>
    ${extra}
    <span class="meta">${fmtDate(f.modified)}</span>
    <span class="size">${fmt(f.size)}</span>
  </div>`);
  const cb = row.querySelector(".cb");
  cb.checked = state.sel.has(f.path);
  row.onclick = (e) => {
    if (e.target !== cb) cb.checked = !cb.checked;
    cb.checked ? state.sel.add(f.path) : state.sel.delete(f.path);
    state.note = "";
    selFooter();
  };
  return row;
}

function fileList(items, label) {
  const total = items.reduce((s, f) => s + f.size, 0);
  $("hero").querySelector(".big").innerHTML = `<b>${fmt(total)}</b><span>${esc(label(items.length))}</span>`;
  if (!items.length) { $("content").innerHTML = `<div class="empty">${L("Nothing found", "Tidak ada yang ditemukan")}</div>`; return; }
  $("content").replaceChildren(...items.slice(0, 500).map((f) => fileRow(f)));
  if (items.length > 500) $("content").append(h(`<div class="empty">${L("Showing the 500 largest", "Menampilkan 500 terbesar")}</div>`));
}

async function moveToBin() {
  const paths = [...state.sel];
  if (!paths.length || !confirm(L(`Move ${paths.length} file(s) to the Recycle Bin?`, `Pindahkan ${paths.length} file ke Recycle Bin?`))) return;
  const failed = await invoke("trash_paths", { paths });
  const done = new Set(paths.filter((p) => !failed.includes(p)));
  if (state.files) state.files = state.files.filter((f) => !done.has(f.path));
  state.sel.clear();
  state.note = L(`${done.size} moved to the Recycle Bin`, `${done.size} dipindahkan ke Recycle Bin`) +
    (failed.length ? L(` · ${failed.length} failed`, ` · ${failed.length} gagal`) : "");
  refreshDisk();
  show(state.tab, true);
}

// ---------- Disk Usage ----------
async function usage() {
  const g = state.gen;
  $("hero").replaceChildren(h(`<div class="big"><b>…</b><span></span></div>`), toolbar());
  $("content").innerHTML = loading(L("Measuring folders…", "Mengukur folder…"));
  setFooter([], []);
  const items = await invoke("scan_dir", { path: state.root }).catch((e) => ({ error: String(e) }));
  if (g !== state.gen) return;
  if (items.error) { $("content").innerHTML = `<div class="empty">${esc(items.error)}</div>`; return; }
  const total = items.reduce((s, e) => s + e.size, 0);
  const max = items[0]?.size || 1;
  $("hero").querySelector(".big").innerHTML = `<b>${fmt(total)}</b><span>${L(`in ${items.length} items`, `dalam ${items.length} item`)}</span>`;
  $("content").replaceChildren(...items.map((e) => {
    const row = h(`<div class="row${e.is_dir ? " click" : ""}">
      ${svg(e.is_dir ? "folder" : "file", "ic")}
      <div class="txt"><b>${esc(e.name)}</b></div>
      <div class="usebar"><div style="width:${(e.size / max) * 100}%"></div></div>
      <span class="size">${fmt(e.size)}</span>
      ${e.is_dir ? svg("chev", "chev") : '<span style="width:14px"></span>'}
    </div>`);
    if (e.is_dir) row.onclick = () => { state.root = e.path; show("usage"); };
    return row;
  }));
}

// ---------- Large / Stale ----------
async function large() {
  const min = h(`<input type="number" min="1" value="100">`);
  const opt = h(`<label>${L("At least", "Minimal")}</label>`);
  opt.append(min, " MB");
  $("hero").replaceChildren(h(`<div class="big"><b>…</b><span></span></div>`), toolbar([opt]));
  selFooter();
  if (!(await ensureFiles())) return;
  const run = () => {
    const m = Math.max(1, +min.value || 100) * (1 << 20);
    fileList(state.files.filter((f) => f.size >= m), (n) => L(`in ${n} large files`, `dalam ${n} file besar`));
  };
  min.onchange = run;
  run();
}

async function stale() {
  const age = h(`<select></select>`);
  for (const [d, t] of [[180, L("6 months", "6 bulan")], [365, L("1 year", "1 tahun")], [730, L("2 years", "2 tahun")]]) age.add(new Option(t, d));
  age.value = "365";
  const min = h(`<input type="number" min="1" value="10">`);
  const o1 = h(`<label>${L("Not modified for", "Tidak diubah selama")}</label>`);
  o1.append(age);
  const o2 = h(`<label>${L("At least", "Minimal")}</label>`);
  o2.append(min, " MB");
  $("hero").replaceChildren(h(`<div class="big"><b>…</b><span></span></div>`), toolbar([o1, o2]));
  selFooter();
  if (!(await ensureFiles())) return;
  const run = () => {
    const cutoff = Date.now() / 1000 - +age.value * 86400;
    const m = Math.max(1, +min.value || 10) * (1 << 20);
    fileList(state.files.filter((f) => f.modified < cutoff && f.size >= m).sort((a, b) => b.size - a.size),
      (n) => L(`in ${n} stale files`, `dalam ${n} file lama`));
  };
  age.onchange = min.onchange = run;
  run();
}

// ---------- Duplicates ----------
async function dupes() {
  const skip = h(`<input type="checkbox" class="cb" checked>`);
  const opt = h(`<label></label>`);
  opt.append(skip, L("Skip system & app folders", "Lewati folder sistem & aplikasi"));
  $("hero").replaceChildren(h(`<div class="big"><b>…</b><span></span></div>`), toolbar([opt]));
  selFooter();
  const g = state.gen;
  if (!(await ensureFiles())) return;
  const run = async () => {
    $("content").innerHTML = loading(L("Comparing files…", "Membandingkan file…"));
    const groups = await invoke("find_dupes", { files: state.files, root: state.filesRoot, skipProtected: skip.checked });
    if (g !== state.gen) return;
    const wasted = groups.reduce((s, x) => s + x.wasted, 0);
    $("hero").querySelector(".big").innerHTML = `<b>${fmt(wasted)}</b><span>${L(`reclaimable in ${groups.length} groups`, `bisa dihemat dari ${groups.length} grup`)}</span>`;
    if (!groups.length) { $("content").innerHTML = `<div class="empty">${L("No duplicates found", "Tidak ada duplikat")}</div>`; return; }
    const rows = [];
    for (const grp of groups.slice(0, 200)) {
      rows.push(h(`<div class="group-head"><span>${L(`${grp.items.length} copies`, `${grp.items.length} salinan`)}</span><span>${fmt(grp.size)} ${L("each", "per file")}</span></div>`));
      grp.items.forEach((f, i) => rows.push(fileRow(f, i === 0 ? `<span class="keep">${L("Oldest", "Terlama")}</span>` : "")));
    }
    $("content").replaceChildren(...rows);
  };
  skip.onchange = run;
  run();
}

// ---------- navigation ----------
function show(tab, keepNote = false) {
  state.gen++;
  state.tab = tab;
  if (!keepNote) state.note = "";
  state.sel.clear();
  document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
  $("title").textContent = T[tab];
  $("hero").innerHTML = "";
  $("content").innerHTML = "";
  $("content").scrollTop = 0;
  setFooter([], []);
  ({ cleanup, usage, large, stale, dupes })[tab]();
}

(async () => {
  initSidebar();
  state.home = await invoke("home_dir");
  state.root = state.home;
  refreshDisk();
  show("cleanup");
})();
