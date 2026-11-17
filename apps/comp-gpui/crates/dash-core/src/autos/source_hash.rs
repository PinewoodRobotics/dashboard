use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// Digest of a raw PathPlanner directory, identical to `source_hash()` in
/// tools/pathplanner/export_autos.py: sha256 over
/// "relpath\nsha256(file)\n" for every file whose path has no dot-prefixed
/// part, sorted by '/'-joined relpath.
pub fn source_hash(root: &Path) -> String {
    let mut rels = Vec::new();
    collect(root, "", &mut rels);
    rels.sort();
    let mut ctx = Sha256::new();
    for rel in rels {
        let digest = fs::read(root.join(&rel))
            .map(|b| sha256_hex(&b))
            .unwrap_or_default();
        ctx.update(format!("{rel}\n{digest}\n").as_bytes());
    }
    hex(&ctx.finalize())
}

fn collect(root: &Path, rel: &str, out: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(root.join(rel)) else {
        return;
    };
    let mut dirs = Vec::new();
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let child = if rel.is_empty() {
            name
        } else {
            format!("{rel}/{name}")
        };
        match entry.file_type() {
            Ok(t) if t.is_dir() => dirs.push(child),
            Ok(_) => out.push(child),
            Err(_) => {}
        }
    }
    for d in dirs {
        collect(root, &d, out);
    }
}
