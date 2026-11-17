use std::{env, fmt::Write as _, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let data = manifest.join("../../../comp-godot/data");
    let autos = data.join("autos");
    println!("cargo:rerun-if-changed={}", autos.display());

    let mut files: Vec<PathBuf> = fs::read_dir(&autos)
        .unwrap_or_else(|e| panic!("built-in auto export {}: {e}", autos.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    files.sort();

    let mut out = String::from("pub(crate) static BUILTIN_EXPORT_FILES: &[(&str, &str)] = &[\n");
    for path in &files {
        println!("cargo:rerun-if-changed={}", path.display());
        let name = path.file_name().unwrap().to_str().unwrap();
        writeln!(
            out,
            "    ({name:?}, include_str!({:?})),",
            path.display().to_string()
        )
        .unwrap();
    }
    out.push_str("];\n");
    for (constant, file) in [
        ("BUILTIN_META", "auto_meta.json"),
        ("BUILTIN_COMMANDS", "auto_commands.json"),
    ] {
        let path = data.join(file);
        println!("cargo:rerun-if-changed={}", path.display());
        writeln!(
            out,
            "pub(crate) static {constant}: &str = include_str!({:?});",
            path.display().to_string()
        )
        .unwrap();
    }
    fs::write(
        PathBuf::from(env::var("OUT_DIR").unwrap()).join("builtin_autos.rs"),
        out,
    )
    .unwrap();
}
