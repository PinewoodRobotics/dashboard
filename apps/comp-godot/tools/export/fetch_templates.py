"""Downloads only the export templates this project uses (Windows arm64 and
x86_64, macOS, ICU data) out of Godot's 1.3 GB templates archive, with HTTP
range requests, and checks each file's CRC. macos.zip ships universal binaries
only, so the arm64 slices are added to it as godot_macos_{debug,release}.arm64,
the names Godot's macOS export looks for when the preset's architecture is arm64.

Usage: python3 fetch_templates.py VERSION DEST_DIR [GLOB ...]
e.g.   python3 fetch_templates.py 4.7.2 ~/.local/share/godot/export_templates/4.7.2.stable
"""

import fnmatch
import io
import struct
import sys
import urllib.request
import zipfile
import zlib
from pathlib import Path

DEFAULT = [
    "templates/version.txt",
    "templates/icudt_godot.dat",
    "templates/macos.zip",
    "templates/windows_*_arm64*.exe",
    "templates/windows_*_x86_64*.exe",
]
CHUNK = 1 << 20
CPU_TYPE_ARM64 = 0x0100000C


def resolve(url: str) -> tuple[str, int]:
    with urllib.request.urlopen(urllib.request.Request(url, method="HEAD")) as r:
        return r.url, int(r.headers["Content-Length"])


def fetch(url: str, start: int, length: int):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}"})
    r = urllib.request.urlopen(req)
    if r.status != 206:
        raise RuntimeError(f"server ignored the range request (HTTP {r.status})")
    return r


class RangeFile(io.RawIOBase):
    def __init__(self, url: str, size: int):
        self.url, self.size, self.pos = url, size, 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, off: int, whence: int = 0) -> int:
        self.pos = [off, self.pos + off, self.size + off][whence]
        return self.pos

    def read(self, n: int = -1) -> bytes:
        n = self.size - self.pos if n < 0 else min(n, self.size - self.pos)
        if n <= 0:
            return b""
        with fetch(self.url, self.pos, n) as r:
            data = r.read()
        self.pos += len(data)
        return data


def extract(url: str, info: zipfile.ZipInfo, dest: Path) -> None:
    with fetch(url, info.header_offset, 30) as r:
        header = r.read()
    name_len, extra_len = struct.unpack_from("<HH", header, 26)
    start = info.header_offset + 30 + name_len + extra_len
    out = dest / Path(info.filename).name
    tmp = out.with_suffix(out.suffix + ".part")
    crc = 0
    inflate = zlib.decompressobj(-15) if info.compress_type == zipfile.ZIP_DEFLATED else None
    with fetch(url, start, info.compress_size) as r, open(tmp, "wb") as f:
        while chunk := r.read(CHUNK):
            data = inflate.decompress(chunk) if inflate else chunk
            crc = zlib.crc32(data, crc)
            f.write(data)
        if inflate:
            tail = inflate.flush()
            crc = zlib.crc32(tail, crc)
            f.write(tail)
    if crc != info.CRC or tmp.stat().st_size != info.file_size:
        tmp.unlink()
        raise RuntimeError(f"{info.filename}: CRC or size mismatch")
    tmp.replace(out)
    print(f"{info.file_size / 1e6:8.1f} MB  {out}")


def arm64_slice(fat: bytes) -> bytes:
    magic, count = struct.unpack_from(">II", fat, 0)
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        raise RuntimeError("not a universal Mach-O binary")
    for i in range(count):
        if magic == 0xCAFEBABE:
            cpu, _, offset, size, _ = struct.unpack_from(">iiIII", fat, 8 + i * 20)
        else:
            cpu, _, offset, size, _, _ = struct.unpack_from(">iiQQII", fat, 8 + i * 32)
        if cpu == CPU_TYPE_ARM64:
            return fat[offset : offset + size]
    raise RuntimeError("no arm64 slice")


def add_macos_arm64(zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "a", zipfile.ZIP_DEFLATED) as z:
        names = set(z.namelist())
        for name in sorted(n for n in names if n.endswith(".universal")):
            thin = name.removesuffix(".universal") + ".arm64"
            if thin in names:
                continue
            info = zipfile.ZipInfo(thin, z.getinfo(name).date_time)
            info.external_attr = 0o100755 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, arm64_slice(z.read(name)))
            print(f"           added {thin}")


def main() -> None:
    version, dest = sys.argv[1], Path(sys.argv[2]).expanduser()
    patterns = sys.argv[3:] or DEFAULT
    base = f"https://github.com/godotengine/godot/releases/download/{version}-stable"
    url, size = resolve(f"{base}/Godot_v{version}-stable_export_templates.tpz")
    infos = zipfile.ZipFile(RangeFile(url, size)).infolist()
    dest.mkdir(parents=True, exist_ok=True)
    for pattern in patterns:
        matches = [i for i in infos if fnmatch.fnmatch(i.filename, pattern)]
        if not matches:
            sys.exit(f"no template matches {pattern}")
        for info in matches:
            extract(url, info, dest)
    if (dest / "macos.zip").exists():
        add_macos_arm64(dest / "macos.zip")


if __name__ == "__main__":
    main()
