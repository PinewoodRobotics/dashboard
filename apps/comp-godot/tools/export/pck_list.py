"""Lists the files in a Godot 4 .pck (format 2 to 4, unencrypted directory)."""

import struct
import sys


def read_pck(path: str) -> list[tuple[str, int]]:
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"GDPC":
        raise SystemExit(f"{path}: not a pck")
    version, _major, _minor, _patch = struct.unpack_from("<4I", data, 4)
    pos = 20
    flags = 0
    if version >= 2:
        flags, _file_base = struct.unpack_from("<IQ", data, pos)
        pos += 12
    if version >= 3:
        (dir_offset,) = struct.unpack_from("<Q", data, pos)
        pos = dir_offset
    else:
        pos += 16 * 4
    if flags & 1:
        raise SystemExit(f"{path}: encrypted directory")
    (count,) = struct.unpack_from("<I", data, pos)
    pos += 4
    out = []
    for _ in range(count):
        (n,) = struct.unpack_from("<I", data, pos)
        pos += 4
        name = data[pos : pos + n].rstrip(b"\0").decode()
        pos += n
        _offset, size = struct.unpack_from("<QQ", data, pos)
        pos += 16 + 16
        if version >= 2:
            pos += 4
        out.append((name if name.startswith("res://") else "res://" + name, size))
    return out


if __name__ == "__main__":
    for name, size in read_pck(sys.argv[1]):
        print(f"{size}\t{name}")
