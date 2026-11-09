const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

function fmt(n) {
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

async function scan(path) {
  $("path").value = path;
  $("status").textContent = "Scanning…";
  $("list").replaceChildren();
  try {
    const items = await invoke("scan_dir", { path });
    const total = items.reduce((s, e) => s + e.size, 0);
    const max = items[0]?.size || 1;
    $("status").textContent = `${items.length} items · ${fmt(total)}`;
    for (const e of items) {
      const li = document.createElement("li");
      if (e.is_dir) { li.className = "dir"; li.onclick = () => scan(e.path); }
      const bar = document.createElement("div");
      bar.className = "bar";
      bar.style.width = `${(e.size / max) * 100}%`;
      const name = document.createElement("span");
      name.textContent = (e.is_dir ? "📁 " : "") + e.name;
      const size = document.createElement("span");
      size.className = "size";
      size.textContent = fmt(e.size);
      li.append(bar, name, size);
      $("list").append(li);
    }
  } catch (err) {
    $("status").textContent = String(err);
  }
}

function parent(p) {
  const i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  return i > 0 ? p.slice(0, i) || p.slice(0, i + 1) : p;
}

$("go").onclick = () => scan($("path").value);
$("path").onkeydown = (e) => { if (e.key === "Enter") scan($("path").value); };
$("up").onclick = () => scan(parent($("path").value));
invoke("home_dir").then(scan);
