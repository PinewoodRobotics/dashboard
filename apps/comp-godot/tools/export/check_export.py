"""Checks an exported build: the Windows exe is a PE32+ x86-64 image with a
separate .pck that holds every runtime file the project loads.

Usage: python3 check_export.py APP_DIR WINDOWS_EXE
"""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pck_list import read_pck  # noqa: E402

app, exe = Path(sys.argv[1]), Path(sys.argv[2])
pck = exe.with_suffix(".pck")
errors: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        errors.append(msg)


head = exe.read_bytes()[:4096]
pe = struct.unpack_from("<I", head, 0x3C)[0] if head[:2] == b"MZ" else -1
check(pe > 0 and head[pe : pe + 4] == b"PE\0\0", f"{exe.name} is a PE image")
if pe > 0:
    machine = struct.unpack_from("<H", head, pe + 4)[0]
    magic = struct.unpack_from("<H", head, pe + 24)[0]
    check(machine == 0x8664 and magic == 0x20B, f"{exe.name} is x86-64 PE32+ (machine {machine:#x}, magic {magic:#x})")
check(pck.exists(), f"{pck.name} next to the exe ({pck.stat().st_size / 1e6:.1f} MB)" if pck.exists() else f"{pck.name} exists")
if errors:
    sys.exit(1)

files = {name: size for name, size in read_pck(str(pck))}
print(f"     {len(files)} files in {pck.name}")


def has(prefix: str, suffix: str = "") -> bool:
    return any(n.startswith(prefix) and n.endswith(suffix) and files[n] > 0 for n in files)


raw_json = sorted(
    "res://" + p.relative_to(app).as_posix()
    for p in app.rglob("*.json")
    if not any(part.startswith(".") for part in p.relative_to(app).parts)
    and p.relative_to(app).parts[0] not in ("tools", "tests", "build")
    and not (p.parent / ".gdignore").exists()
    and not any((app / Path(*p.relative_to(app).parts[:i]) / ".gdignore").exists() for i in range(1, len(p.relative_to(app).parts)))
)
missing = [n for n in raw_json if n not in files]
check(not missing, f"all {len(raw_json)} project JSON files are in the pck (data/**, lucide.json, manifest) {missing[:5]}")
for must in ("res://ui/icons/lucide.json", "res://data/autos/index.json", "res://data/rig/robot-rig.json",
             "res://assets/models/models.manifest.json", "res://data/auto_commands.json"):
    check(must in files, f"{must}")
for model in ("robot", "field"):
    check(f"res://assets/models/{model}.glb.import" in files, f"{model}.glb import remap")
    check(has(f"res://.godot/imported/{model}.glb-", ".scn"), f"{model}.glb imported scene")
for font in [f"Inter-{w}" for w in (300, 400, 500, 600, 700)] + ["RobotoMono-400", "RobotoMono-500"]:
    check(has(f"res://.godot/imported/{font}.ttf-", ".fontdata"), f"{font} font data")
howard = [n for n in files if n.startswith("res://.godot/imported/") and n.endswith(".ctex")]
check(len(howard) >= 6, f"Howard textures ({len(howard)})")
check(has("res://app/main.gdc") or has("res://app/main.gd"), "compiled main script")
check("res://project.binary" in files, "project.binary")
leaked = [n for n in files if n.startswith(("res://tests/", "res://tools/", "res://.scratch/", "res://build/", "res://.screenshots/"))]
check(not leaked, f"no test, tool or scratch files {leaked[:5]}")
sys.exit(1 if errors else 0)
