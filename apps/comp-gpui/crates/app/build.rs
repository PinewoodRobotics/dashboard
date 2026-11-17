use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::BufReader;
use std::path::{Path, PathBuf};

const ANIMATED: &str = "../../../comp/public/path-overview/animated";

fn main() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join(ANIMATED);
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    println!("cargo:rerun-if-changed={}", src.display());
    println!("cargo:rerun-if-changed=build.rs");

    let mut gifs: Vec<PathBuf> = fs::read_dir(&src)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "gif"))
                .collect()
        })
        .unwrap_or_else(|e| {
            println!(
                "cargo:warning=no path-overview GIFs at {}: {e}",
                src.display()
            );
            Vec::new()
        });
    gifs.sort();

    let dir = out.join("path-overview");
    fs::create_dir_all(&dir).unwrap();
    let mut table = String::from("&[\n");
    for (i, gif) in gifs.iter().enumerate() {
        println!("cargo:rerun-if-changed={}", gif.display());
        let name = gif.file_stem().unwrap().to_str().unwrap();
        let png = dir.join(format!("{i}.png"));
        first_frame_png(gif, &png).unwrap_or_else(|e| panic!("{}: {e}", gif.display()));
        writeln!(
            table,
            "    ({name:?}, include_bytes!({:?})),",
            png.display()
        )
        .unwrap();
    }
    table.push(']');
    fs::write(out.join("path_overview.rs"), table).unwrap();
}

/// The GIF's first frame composited onto a transparent canvas, as PNG: the
/// app only shows that frame, and the whole GIFs are 40+ MB.
fn first_frame_png(gif: &Path, png: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut opts = gif::DecodeOptions::new();
    opts.set_color_output(gif::ColorOutput::RGBA);
    let mut dec = opts.read_info(BufReader::new(File::open(gif)?))?;
    let (w, h) = (dec.width() as usize, dec.height() as usize);
    let frame = dec.read_next_frame()?.ok_or("no frames")?;
    let mut canvas = vec![0u8; w * h * 4];
    let (fl, ft, fw) = (
        frame.left as usize,
        frame.top as usize,
        frame.width as usize,
    );
    for (row, src) in frame.buffer.chunks_exact(fw * 4).enumerate() {
        let y = ft + row;
        if y >= h {
            break;
        }
        let n = fw.min(w.saturating_sub(fl));
        let at = (y * w + fl) * 4;
        canvas[at..at + n * 4].copy_from_slice(&src[..n * 4]);
    }
    let mut enc = png::Encoder::new(File::create(png)?, w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_compression(png::Compression::Balanced);
    enc.write_header()?.write_image_data(&canvas)?;
    Ok(())
}
