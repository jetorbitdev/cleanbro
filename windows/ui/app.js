const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);
const DAY = 86400;
const MB = 1 << 20;

const state = { tab: "cleanup", files: null, filesRoot: "", sel: new Set(), dupes: [] };

function fmt(n) {
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}
const fmtDate = (s) => (s ? new Date(s * 1000).toLocaleDateString() : "—");
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};
function parent(p) {
  const i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  return i > 0 ? p.slice(0, i) || p.slice(0, i + 1) : p;
}

// ---------- selection footer ----------
function updateFoot(sizeOf) {
  const n = state.sel.size;
  $("foot").hidden = n === 0;
  $("sel").textContent = `${n} selected · ${fmt(sizeOf())}`;
}
let sizeLookup = new Map();
function toggle(path, li) {
  state.sel.has(path) ? state.sel.delete(path) : state.sel.add(path);
  li.classList.toggle("sel", state.sel.has(path));
  updateFoot(() => [...state.sel].reduce((s, p) => s + (sizeLookup.get(p) || 0), 0));
}

function fileRow(f, extra) {
  sizeLookup.set(f.path, f.size);
  const li = el("li", "file" + (state.sel.has(f.path) ? " sel" : ""));
  const name = el("span", "name", f.name);
  name.append(el("small", "", f.path));
  li.append(name, el("span", "date", fmtDate(f.modified)), el("span", "size", fmt(f.size)));
  if (extra) li.append(extra);
  li.onclick = () => toggle(f.path, li);
  return li;
}

// ---------- Cleanup ----------
const CAT = {
  temp: "Temporary files",
  cache: "App & browser caches",
  logs: "Crash dumps & error reports",
  dev: "Developer caches",
  dl: "Incomplete downloads",
  recycle: "Recycle Bin",
};

async function cleanupTab() {
  $("status").textContent = "Scanning…";
  let cats;
  try { cats = await invoke("scan_junk"); }
  catch (err) { $("status").textContent = String(err); return; }
  const total = cats.reduce((s, c) => s + c.items.reduce((t, i) => t + i.size, 0), 0);
  $("status").textContent = total ? `${fmt(total)} can be cleaned` : "Already clean";
  const rows = [];
  for (const c of cats) {
    const sum = c.items.reduce((s, i) => s + i.size, 0);
    const head = el("li", "head");
    head.append(el("span", "", CAT[c.id] || c.id),
      el("span", "size", c.needs_access ? "Needs admin rights" : c.items.length ? fmt(sum) : "Already clean"));
    const lis = c.items.map((i) => fileRow({ name: i.name, path: i.path, size: i.size, modified: 0 }));
    head.style.cursor = c.items.length ? "pointer" : "default";
    head.onclick = () => {
      const all = c.items.every((i) => state.sel.has(i.path));
      c.items.forEach((i, k) => {
        all ? state.sel.delete(i.path) : state.sel.add(i.path);
        lis[k].classList.toggle("sel", !all);
      });
      updateFoot(() => [...state.sel].reduce((s, p) => s + (sizeLookup.get(p) || 0), 0));
    };
    rows.push(head, ...lis);
  }
  $("list").replaceChildren(...rows);
}

// ---------- Disk Usage ----------
async function usage(path) {
  $("path").value = path;
  $("status").textContent = "Scanning…";
  $("list").replaceChildren();
  try {
    const items = await invoke("scan_dir", { path });
    const total = items.reduce((s, e) => s + e.size, 0);
    const max = items[0]?.size || 1;
    $("status").textContent = `${items.length} items · ${fmt(total)}`;
    for (const e of items) {
      const li = el("li", e.is_dir ? "dir" : "");
      if (e.is_dir) li.onclick = () => usage(e.path);
      const bar = el("div", "bar");
      bar.style.width = `${(e.size / max) * 100}%`;
      li.append(bar, el("span", "", (e.is_dir ? "📁 " : "") + e.name), el("span", "size", fmt(e.size)));
      $("list").append(li);
    }
  } catch (err) { $("status").textContent = String(err); }
}

// ---------- shared file scan (Large / Stale / Dupes) ----------
async function ensureFiles() {
  const root = $("path").value;
  if (state.files && state.filesRoot === root) return true;
  $("status").textContent = "Scanning…";
  $("list").replaceChildren();
  try {
    state.files = await invoke("scan_files", { root, minBytes: MB });
    state.filesRoot = root;
    state.sel.clear();
    return true;
  } catch (err) {
    state.files = null;
    $("status").textContent = String(err);
    return false;
  }
}

function listFiles(items, label) {
  $("list").replaceChildren(...items.slice(0, 500).map((f) => fileRow(f)));
  const total = items.reduce((s, f) => s + f.size, 0);
  $("status").textContent = `${items.length} ${label} · ${fmt(total)}` + (items.length > 500 ? " (showing 500)" : "");
  updateFoot(() => [...state.sel].reduce((s, p) => s + (sizeLookup.get(p) || 0), 0));
}

function largeTab() {
  $("opts").replaceChildren(
    el("span", "", "Min size (MB)"),
    Object.assign(el("input"), { id: "min", type: "number", value: 100, min: 1, style: "width:80px" }),
  );
  const run = async () => {
    if (!(await ensureFiles())) return;
    const min = Math.max(1, +$("min").value || 100) * MB;
    listFiles(state.files.filter((f) => f.size >= min), "large files");
  };
  $("min").onchange = run;
  return run();
}

function staleTab() {
  const sel = Object.assign(el("select"), { id: "age" });
  for (const [d, t] of [[180, "6 months"], [365, "1 year"], [730, "2 years"]]) sel.add(new Option(t, d));
  sel.value = 365;
  const min = Object.assign(el("input"), { id: "min", type: "number", value: 10, min: 1, style: "width:80px" });
  $("opts").replaceChildren(el("span", "", "Not modified for"), sel, el("span", "", "Min size (MB)"), min);
  const run = async () => {
    if (!(await ensureFiles())) return;
    const cutoff = Date.now() / 1000 - +sel.value * DAY;
    const minB = Math.max(1, +min.value || 10) * MB;
    listFiles(state.files.filter((f) => f.modified < cutoff && f.size >= minB), "stale files");
  };
  sel.onchange = min.onchange = run;
  return run();
}

async function dupesTab() {
  const skip = Object.assign(el("input"), { type: "checkbox", checked: true });
  const lab = el("label");
  lab.append(skip, " Skip system & app folders");
  $("opts").replaceChildren(lab);
  const run = async () => {
    if (!(await ensureFiles())) return;
    $("status").textContent = "Comparing files…";
    $("list").replaceChildren();
    const groups = await invoke("find_dupes", { files: state.files, root: state.filesRoot, skipProtected: skip.checked });
    const wasted = groups.reduce((s, g) => s + g.wasted, 0);
    $("status").textContent = `${groups.length} groups · ${fmt(wasted)} reclaimable`;
    const rows = [];
    for (const g of groups.slice(0, 200)) {
      rows.push(el("li", "head", `${g.items.length} copies · ${fmt(g.size)} each`));
      // the oldest copy (first) is the one we keep by default
      g.items.forEach((f, i) => rows.push(fileRow(f, i === 0 ? el("span", "date", "keep") : null)));
    }
    $("list").replaceChildren(...rows);
    updateFoot(() => [...state.sel].reduce((s, p) => s + (sizeLookup.get(p) || 0), 0));
  };
  skip.onchange = run;
  return run();
}

// ---------- tabs ----------
async function show(tab) {
  state.tab = tab;
  document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
  $("opts").replaceChildren();
  $("list").replaceChildren();
  state.sel.clear();
  updateFoot(() => 0);
  $("bar").hidden = tab === "cleanup";
  $("trash").textContent = tab === "cleanup" ? "Delete permanently" : "Move to Recycle Bin";
  if (tab === "cleanup") return cleanupTab();
  if (tab === "usage") return usage($("path").value);
  if (tab === "large") return largeTab();
  if (tab === "stale") return staleTab();
  if (tab === "dupes") return dupesTab();
}

document.querySelectorAll("#tabs button").forEach((b) => (b.onclick = () => show(b.dataset.tab)));
$("go").onclick = () => { state.files = null; show(state.tab); };
$("path").onkeydown = (e) => { if (e.key === "Enter") $("go").click(); };
$("up").onclick = () => { $("path").value = parent($("path").value); $("go").click(); };

$("trash").onclick = async () => {
  const paths = [...state.sel];
  if (state.tab === "cleanup") {
    if (!paths.length || !confirm(`Permanently delete ${paths.length} item(s)? This cannot be undone.`)) return;
    const r = await invoke("clean_junk", { paths });
    await show("cleanup");
    $("status").textContent = `Freed ${fmt(r.freed)}` + (r.failed.length ? ` · ${r.failed.length} in use or protected, skipped` : "");
    return;
  }
  if (!paths.length || !confirm(`Move ${paths.length} file(s) to the Recycle Bin?`)) return;
  const failed = await invoke("trash_paths", { paths });
  state.files = state.files?.filter((f) => !paths.includes(f.path) || failed.includes(f.path)) ?? null;
  state.sel.clear();
  await show(state.tab);
  if (failed.length) $("status").textContent += ` · ${failed.length} could not be moved`;
};

invoke("home_dir").then((h) => { $("path").value = h; show("cleanup"); });
