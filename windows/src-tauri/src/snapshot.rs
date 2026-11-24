//! The last analysis, saved to disk so the app opens on its results instead of
//! an empty screen. A compact binary file (a home folder is a few hundred
//! thousand nodes, too many for JSON): header, scan details, the files of 1 MB
//! or more, then the folder tree. Anything unexpected reads as "no snapshot".

use crate::files::FileInfo;
use crate::scan::{Analysis, Meta, Node};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const MAGIC: &[u8; 4] = b"CBSN";
const END: &[u8; 4] = b"END!";
const VERSION: u32 = 1;
/// Deeper than any real folder tree; stops a damaged file from recursing forever.
const MAX_DEPTH: usize = 4096;
const MAX_STR: usize = 1 << 20;

static FILE: OnceLock<PathBuf> = OnceLock::new();

/// Where the snapshot lives. Called once at startup.
pub fn init(dir: PathBuf) {
    let _ = FILE.set(dir.join("last-scan.bin"));
}

/// Writes the snapshot next to the old one and swaps it in, so a crash midway
/// never leaves a half-written file. Failures are ignored: the snapshot is a
/// convenience, never a reason to fail a scan.
pub fn save(a: &Analysis) {
    let Some(path) = FILE.get() else { return };
    let tmp = path.with_extension("tmp");
    let result = (|| -> io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut w = BufWriter::new(File::create(&tmp)?);
        write_to(a, &mut w)?;
        w.flush()?;
        drop(w);
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

/// The saved analysis, if there is a valid one whose folder still exists.
pub fn load() -> Option<Analysis> {
    let file = File::open(FILE.get()?).ok()?;
    let a = read_from(&mut BufReader::with_capacity(1 << 20, file)).ok()?;
    a.root.is_dir().then_some(a)
}

// ---------- format ----------

fn put_u64(w: &mut impl Write, v: u64) -> io::Result<()> {
    w.write_all(&v.to_le_bytes())
}
fn put_str(w: &mut impl Write, s: &str) -> io::Result<()> {
    w.write_all(&(s.len() as u32).to_le_bytes())?;
    w.write_all(s.as_bytes())
}

pub(crate) fn write_to(a: &Analysis, w: &mut (impl Write + Send)) -> io::Result<()> {
    w.write_all(MAGIC)?;
    w.write_all(&VERSION.to_le_bytes())?;
    put_str(w, &a.root.to_string_lossy())?;
    let m = &a.meta;
    for v in [m.dirs, m.files, m.unreadable, m.at, m.secs.to_bits(), m.partial as u64] {
        put_u64(w, v)?;
    }
    put_u64(w, a.files.len() as u64)?;
    for f in &a.files {
        // the name is the last part of the path
        put_str(w, &f.path)?;
        put_u64(w, f.size)?;
        put_u64(w, f.modified)?;
    }
    // the tree recurses once per folder level: run it on the scan pool, which has big stacks
    crate::scan::on_big_stack(|| write_node(&a.tree, w))?;
    w.write_all(END)
}

fn write_node(n: &Node, w: &mut (impl Write + Send)) -> io::Result<()> {
    put_str(w, &n.name)?;
    put_u64(w, n.size)?;
    put_u64(w, n.modified)?;
    w.write_all(&(n.children.len() as u32).to_le_bytes())?;
    n.children.iter().try_for_each(|c| write_node(c, w))
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}
fn get_u32(r: &mut impl Read) -> io::Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}
fn get_u64(r: &mut impl Read) -> io::Result<u64> {
    let mut b = [0u8; 8];
    r.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}
fn get_str(r: &mut impl Read) -> io::Result<String> {
    let n = get_u32(r)? as usize;
    if n > MAX_STR {
        return Err(bad("string too long"));
    }
    let mut b = vec![0u8; n];
    r.read_exact(&mut b)?;
    String::from_utf8(b).map_err(|_| bad("not utf-8"))
}

pub(crate) fn read_from(r: &mut (impl Read + Send)) -> io::Result<Analysis> {
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if &magic != MAGIC || get_u32(r)? != VERSION {
        return Err(bad("not a snapshot of this version"));
    }
    let root = PathBuf::from(get_str(r)?);
    let meta = Meta {
        dirs: get_u64(r)?,
        files: get_u64(r)?,
        unreadable: get_u64(r)?,
        at: get_u64(r)?,
        secs: f64::from_bits(get_u64(r)?),
        partial: get_u64(r)? != 0,
    };
    let n = get_u64(r)?;
    // counts come from the file: never reserve more than a sane first chunk
    let mut files = Vec::with_capacity(n.min(1 << 16) as usize);
    for _ in 0..n {
        let path = get_str(r)?;
        let name = Path::new(&path).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        files.push(FileInfo { name, path, size: get_u64(r)?, modified: get_u64(r)? });
    }
    let tree = crate::scan::on_big_stack(|| read_node(r, 0))?;
    let mut end = [0u8; 4];
    r.read_exact(&mut end)?;
    if &end != END {
        return Err(bad("truncated"));
    }
    Ok(Analysis { root, tree, files, meta })
}

fn read_node(r: &mut (impl Read + Send), depth: usize) -> io::Result<Node> {
    if depth > MAX_DEPTH {
        return Err(bad("tree too deep"));
    }
    let name: Box<str> = get_str(r)?.into();
    let size = get_u64(r)?;
    let modified = get_u64(r)?;
    let n = get_u32(r)? as usize;
    let mut children = Vec::with_capacity(n.min(1 << 12));
    for _ in 0..n {
        children.push(read_node(r, depth + 1)?);
    }
    Ok(Node { name, size, modified, children })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(name: &str, size: u64, modified: u64, children: Vec<Node>) -> Node {
        Node { name: name.into(), size, modified, children }
    }

    fn sample() -> Analysis {
        let tree = node(
            "C:\\Users\\me",
            300,
            50,
            vec![
                node("Downloads", 200, 50, vec![node("Ünï cödé", 0, 0, vec![])]),
                node("Docs", 100, 20, vec![]),
            ],
        );
        let files = vec![FileInfo { name: "a.iso".into(), path: "C:\\Users\\me\\Downloads\\a.iso".into(), size: 200, modified: 50 }];
        let meta = Meta { dirs: 4, files: 9, unreadable: 1, partial: true, secs: 1.5, at: 1_700_000_000 };
        Analysis { root: std::env::temp_dir(), tree, files, meta }
    }

    fn encode(a: &Analysis) -> Vec<u8> {
        let mut buf = Vec::new();
        write_to(a, &mut buf).unwrap();
        buf
    }

    #[test]
    fn roundtrip_keeps_everything() {
        let a = sample();
        let b = read_from(&mut encode(&a).as_slice()).unwrap();
        assert_eq!(b.root, a.root);
        assert_eq!(
            (b.meta.dirs, b.meta.files, b.meta.unreadable, b.meta.partial, b.meta.secs, b.meta.at),
            (4, 9, 1, true, 1.5, 1_700_000_000)
        );
        assert_eq!(b.files.len(), 1);
        assert_eq!((b.files[0].name.as_str(), b.files[0].size, b.files[0].modified), ("a.iso", 200, 50));
        assert_eq!(b.tree.children.len(), 2);
        assert_eq!(&*b.tree.children[0].name, "Downloads");
        assert_eq!(&*b.tree.children[0].children[0].name, "Ünï cödé");
        assert_eq!((b.tree.size, b.tree.modified), (300, 50));
    }

    #[test]
    fn save_then_load_through_the_file() {
        // the only test that sets the snapshot location (it can be set once)
        let dir = std::env::temp_dir().join(format!("cleanbro-snap-{}", std::process::id()));
        init(dir.clone());
        assert!(load().is_none(), "nothing saved yet");
        let mut a = sample();
        save(&a);
        a.tree.size = 123; // a second save replaces the first
        save(&a);
        let b = load().expect("snapshot");
        assert_eq!(b.tree.size, 123);
        assert_eq!(b.meta.at, 1_700_000_000);
        assert!(!dir.join("last-scan.tmp").exists(), "temp file is swapped away");
        // a damaged file reads as no snapshot
        fs::write(dir.join("last-scan.bin"), b"garbage").unwrap();
        assert!(load().is_none());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn damaged_files_are_rejected() {
        let good = encode(&sample());
        // every truncation fails, never panics
        for n in 0..good.len() {
            assert!(read_from(&mut &good[..n]).is_err(), "cut at {n}");
        }
        let mut wrong = good.clone();
        wrong[0] = b'X';
        assert!(read_from(&mut wrong.as_slice()).is_err());
        let mut old = good.clone();
        old[4] = 99;
        assert!(read_from(&mut old.as_slice()).is_err());
    }

    #[test]
    fn deep_tree_does_not_overflow() {
        let mut n = node("leaf", 1, 1, vec![]);
        for i in 0..3000 {
            n = node(&format!("d{i}"), 1, 1, vec![n]);
        }
        let mut a = sample();
        a.tree = n;
        let b = read_from(&mut encode(&a).as_slice()).unwrap();
        let mut depth = 0;
        let mut cur = &b.tree;
        while let Some(c) = cur.children.first() {
            depth += 1;
            cur = c;
        }
        assert_eq!(depth, 3000);
    }
}
