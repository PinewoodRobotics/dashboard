"""Checks the exported macOS zip without macOS tools, so it also runs on the
Linux CI runner: the app binary is a thin arm64 Mach-O with an ad-hoc code
signature (LC_CODE_SIGNATURE whose CodeDirectory has the adhoc flag), the
bundle has its sealed resources and the pck, and the binary is executable.

Usage: python3 check_macos.py PWRUP-Comp.zip
"""

import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CS_ADHOC = 0x2

errors: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        errors.append(msg)


def code_directory_flags(binary: bytes) -> int | None:
    ncmds = struct.unpack_from("<I", binary, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, _ = struct.unpack_from("<II", binary, off + 8)
            magic, _, count = struct.unpack_from(">III", binary, dataoff)
            if magic != CSMAGIC_EMBEDDED_SIGNATURE:
                return None
            for i in range(count):
                _, blob = struct.unpack_from(">II", binary, dataoff + 12 + i * 8)
                if struct.unpack_from(">I", binary, dataoff + blob)[0] == CSMAGIC_CODEDIRECTORY:
                    return struct.unpack_from(">I", binary, dataoff + blob + 12)[0]
            return None
        off += size
    return None


z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
apps = sorted({n.split(".app/")[0] + ".app" for n in names if ".app/" in n})
check(len(apps) == 1, f"one app bundle in the zip {apps}")
app = apps[0] if apps else ""
macos = [n for n in names if n.startswith(f"{app}/Contents/MacOS/") and not n.endswith("/")]
check(len(macos) == 1, f"one binary in Contents/MacOS {macos}")
if macos:
    info = z.getinfo(macos[0])
    binary = z.read(info)
    magic, cpu = struct.unpack_from("<II", binary, 0)
    check(magic == MH_MAGIC_64 and cpu == CPU_TYPE_ARM64, f"thin arm64 Mach-O (magic {magic:#x}, cpu {cpu:#x})")
    flags = code_directory_flags(binary) if magic == MH_MAGIC_64 else None
    check(flags is not None and flags & CS_ADHOC != 0, f"ad-hoc code signature (CodeDirectory flags {flags})")
    check((info.external_attr >> 16) & 0o111 != 0, f"binary is executable ({oct(info.external_attr >> 16)})")
check(f"{app}/Contents/_CodeSignature/CodeResources" in names, "sealed resources (_CodeSignature/CodeResources)")
pcks = [n for n in names if n.startswith(f"{app}/Contents/Resources/") and n.endswith(".pck")]
check(len(pcks) == 1 and z.getinfo(pcks[0]).file_size > 50_000_000, f"pck in Contents/Resources {pcks}")
sys.exit(1 if errors else 0)
