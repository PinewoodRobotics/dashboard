# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["robotpy-pathplannerlib==2026.1.2"]
#
# [tool.uv]
# exclude-newer = "2026-11-01T00:00:00Z"
# ///
"""Compare a real autonomous run with the dashboard's auto preview.

Reads an AdvantageKit log (the robot's own .wpilog from the USB stick, or an
AdvantageScope or driver-station capture of the /AdvantageKit NT tree), finds
every enabled autonomous period, and compares it with the exported auto the
robot had selected (data/autos/<name>.json):

- path: the logged odometry against the exported samples for the logged
  alliance, aligned at the start of autonomous, with the start offset, the RMS
  and maximum position error, the heading error, and the time lag that best
  lines them up (start delay plus control lag);
- events: when each exported command starts, next to when the shooter first
  reports spun up and when the wrist starts and stops moving, with the measured
  wrist travel time against travel_s in data/auto_commands.json.

Nothing here regenerates trajectories: the export is the reference.

Usage (from apps/comp-godot):
  uv run --script tools/pathplanner/compare_auto_log.py LOG.wpilog [--auto NAME]
      [--alliance red|blue] [--autos DIR] [--json OUT]
  uv run --script tools/pathplanner/compare_auto_log.py --selftest
"""

from __future__ import annotations

import argparse
import bisect
import json
import math
import random
import struct
import sys
import tempfile
from pathlib import Path

APP = Path(__file__).resolve().parents[2]
WRIST_MOVING_ROT_S = 0.05
WRIST_SETTLED_ROT = 0.01


def short_key(name: str) -> str:
    for marker in ("RealOutputs/", "DriverStation/", "matchhud/state/", "FMSInfo/"):
        i = name.find(marker)
        if i >= 0:
            prefix = "DS/" if marker == "DriverStation/" else ("FMS/" if marker == "FMSInfo/" else "")
            return prefix + name[i + len(marker):]
    return name


class Series:
    def __init__(self) -> None:
        self.t: list[float] = []
        self.v: list = []

    def add(self, t: float, v) -> None:
        self.t.append(t)
        self.v.append(v)

    def at(self, t: float, default=None):
        i = bisect.bisect_right(self.t, t) - 1
        return self.v[i] if i >= 0 else default

    def lerp(self, t: float):
        i = bisect.bisect_right(self.t, t) - 1
        if i < 0:
            return None
        if i + 1 >= len(self.t) or not isinstance(self.v[i], (int, float)):
            return self.v[i]
        t0, t1 = self.t[i], self.t[i + 1]
        f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
        return self.v[i] + (self.v[i + 1] - self.v[i]) * f


WANTED = {
    "DS/Enabled", "DS/Autonomous", "DS/RobotMode", "DS/AllianceStation", "FMS/IsRedAlliance", "is_red_alliance",
    "PathPlanner/CurrentSelectedAuto", "Odometry/Position", "Odometry/Robot", "Global/pose",
    "IntakeSubsystem/WristPosition", "Shooter/IsSpunUp", "Shooter/RequestedVelocityRPM", "MatchStatus/isShooting",
    "Turret/PositionRot",
}


def read_log(path: Path) -> dict[str, Series]:
    from wpiutil.log import DataLogReader

    reader = DataLogReader(str(path))
    if not reader.isValid():
        raise SystemExit(f"{path}: not a wpilog file")
    entries: dict[int, tuple[str, str]] = {}
    out: dict[str, Series] = {}
    for rec in reader:
        if rec.isStart():
            d = rec.getStartData()
            key = short_key(d.name)
            if key in WANTED:
                entries[d.entry] = (key, d.type)
            continue
        if rec.isControl() or rec.getEntry() not in entries:
            continue
        key, typ = entries[rec.getEntry()]
        t = rec.getTimestamp() / 1e6
        if typ == "boolean":
            v = rec.getBoolean()
        elif typ == "double":
            v = rec.getDouble()
        elif typ == "float":
            v = rec.getFloat()
        elif typ == "int64":
            v = rec.getInteger()
        elif typ == "string":
            v = rec.getString()
        elif typ == "struct:Pose2d":
            raw = bytes(rec.getRaw())
            if len(raw) < 24:
                continue
            v = struct.unpack("<3d", raw[:24])
        else:
            continue
        out.setdefault(key, Series()).add(t, v)
    return out


def auto_windows(log: dict[str, Series]) -> list[tuple[float, float]]:
    # WPILib 2027 logs DriverStation/RobotMode ("AUTONOMOUS", ...) instead of the Autonomous flag.
    en = log.get("DS/Enabled")
    au = log.get("DS/Autonomous") or log.get("DS/RobotMode")
    if en is None or au is None:
        return []
    times = sorted(set(en.t) | set(au.t))
    windows, start = [], None
    for t in times:
        mode = au.at(t, False)
        on = bool(en.at(t, False)) and (mode == "AUTONOMOUS" if isinstance(mode, str) else bool(mode))
        if on and start is None:
            start = t
        elif not on and start is not None:
            windows.append((start, t))
            start = None
    if start is not None:
        windows.append((start, max(times[-1], start)))
    return windows


def logged_red(log: dict[str, Series], t: float) -> bool | None:
    for key in ("FMS/IsRedAlliance", "is_red_alliance"):
        if key in log:
            return bool(log[key].at(t, False))
    if "DS/AllianceStation" in log:
        st = log["DS/AllianceStation"].at(t)
        if st is not None:
            return int(st) in (1, 2, 3)
    return None


def pose_series(log: dict[str, Series]) -> Series | None:
    for key in ("Odometry/Robot", "Odometry/Position", "Global/pose"):
        if key in log and log[key].t:
            return log[key]
    return None


def wrap(a: float) -> float:
    return (a + math.pi) % (2 * math.pi) - math.pi


def path_errors(pose: Series, t0: float, samples: dict, dt: float, lag: float, until: float) -> dict:
    sq, worst, head, n = 0.0, 0.0, 0.0, 0
    xs, ys, hs = samples["x"], samples["y"], samples["heading"]
    for i in range(len(xs)):
        t = i * dt
        if t > until:
            break
        p = pose.at(t0 + t + lag)
        if p is None:
            continue
        e = math.hypot(p[0] - xs[i], p[1] - ys[i])
        sq += e * e
        worst = max(worst, e)
        head = max(head, abs(wrap(p[2] - hs[i])))
        n += 1
    if n == 0:
        return {}
    return {"rms_m": math.sqrt(sq / n), "max_m": worst, "max_heading_deg": math.degrees(head), "samples": n}


def wrist_moves(log: dict[str, Series], t0: float, t1: float) -> list[dict]:
    s = log.get("IntakeSubsystem/WristPosition")
    if s is None:
        return []
    moves, cur = [], None
    for i in range(1, len(s.t)):
        a, b = s.t[i - 1], s.t[i]
        if b < t0 or a > t1 or b <= a:
            continue
        rate = abs(s.v[i] - s.v[i - 1]) / (b - a)
        if rate > WRIST_MOVING_ROT_S:
            if cur is None:
                cur = {"t0": a - t0, "from": s.v[i - 1]}
            cur["t1"], cur["to"] = b - t0, s.v[i]
        elif cur is not None and abs(s.v[i] - cur["to"]) <= WRIST_SETTLED_ROT:
            cur["travel_s"] = cur["t1"] - cur["t0"]
            moves.append(cur)
            cur = None
    if cur is not None:
        cur["travel_s"] = cur["t1"] - cur["t0"]
        moves.append(cur)
    return moves


def first_true(log: dict[str, Series], key: str, t0: float, t1: float) -> float | None:
    s = log.get(key)
    if s is None:
        return None
    if s.at(t0, False):
        return 0.0
    for t, v in zip(s.t, s.v):
        if t0 <= t <= t1 and bool(v):
            return t - t0
    return None


def compare_window(log: dict[str, Series], t0: float, t1: float, autos_dir: Path, auto_name: str | None,
                   alliance: str | None, commands: dict) -> dict:
    sel = log.get("PathPlanner/CurrentSelectedAuto")
    name = auto_name or (sel.at(t0) if sel is not None else None)
    out: dict = {"start_s": t0, "length_s": t1 - t0, "auto": name}
    if not name or name == "NONE":
        out["error"] = "no auto selected in the log (pass --auto)"
        return out
    path = autos_dir / f"{name}.json"
    if not path.exists():
        out["error"] = f"{name} is not in {autos_dir}"
        return out
    exp = json.loads(path.read_text())
    red = {"red": True, "blue": False}.get(alliance or "", logged_red(log, t0))
    if red is None:
        out["error"] = "alliance unknown (pass --alliance)"
        return out
    side = "red" if red else "blue"
    out["alliance"] = side
    pose = pose_series(log)
    samples = (exp.get("samples") or {}).get(side)
    until = min(float(exp["duration_s"]), t1 - t0)
    if pose is not None and samples:
        p = pose.at(t0) or pose.lerp(t0)
        start = exp["start_pose"][side]
        if p is not None:
            out["start_offset_m"] = math.hypot(p[0] - start[0], p[1] - start[1])
            out["start_heading_deg"] = math.degrees(abs(wrap(p[2] - start[2])))
        dt = float(exp["dt"])
        out["path"] = path_errors(pose, t0, samples, dt, 0.0, until)
        best = min((path_errors(pose, t0, samples, dt, k * 0.02, until).get("rms_m", math.inf), k * 0.02)
                   for k in range(-25, 51))
        out["best_lag_s"] = best[1]
        out["path_at_best_lag"] = path_errors(pose, t0, samples, dt, best[1], until)
        end = pose.at(t0 + until)
        if end is not None:
            xe, ye = samples["x"][-1], samples["y"][-1]
            out["end_error_m"] = math.hypot(end[0] - xe, end[1] - ye)
    elif samples:
        out["path_note"] = "no odometry pose in the log"
    out["events"] = [{"name": e["name"], "t0": e["t0"], "t1": e["t1"]} for e in exp.get("events", [])]
    spun = first_true(log, "Shooter/IsSpunUp", t0, t1)
    shooting = first_true(log, "MatchStatus/isShooting", t0, t1)
    out["measured"] = {"shooter_spun_up_s": spun, "is_shooting_s": shooting, "wrist_moves": wrist_moves(log, t0, t1)}
    shooter_cmd = next((e for e in exp.get("events", []) if e["name"] == "ContinuousShooterCommand"), None)
    if shooter_cmd is not None and spun is not None:
        out["shooter_spin_up_after_command_s"] = spun - float(shooter_cmd["t0"])
    travel = commands.get("wrist", {}).get("travel_s")
    moves = out["measured"]["wrist_moves"]
    if moves and travel is not None:
        out["wrist_travel_model_s"] = travel
        out["wrist_travel_measured_s"] = sorted(m["travel_s"] for m in moves)
    return out


def fmt(v, unit="", digits=2) -> str:
    return "-" if v is None else f"{v:.{digits}f}{unit}"


def print_report(r: dict) -> None:
    print(f"== auto period at {r['start_s']:.2f} s, {r['length_s']:.1f} s long: {r.get('auto')}")
    if "error" in r:
        print("   " + r["error"])
        return
    print(f"   alliance {r['alliance']}")
    if "start_offset_m" in r:
        print(f"   start pose off by {fmt(r['start_offset_m'], ' m')} / {fmt(r['start_heading_deg'], ' deg', 0)}")
    if r.get("path"):
        p, b = r["path"], r["path_at_best_lag"]
        print(f"   path error  rms {fmt(p['rms_m'], ' m')}  max {fmt(p['max_m'], ' m')}  heading max {fmt(p['max_heading_deg'], ' deg', 1)}")
        print(f"   best lag {r['best_lag_s']:+.2f} s: rms {fmt(b['rms_m'], ' m')}  max {fmt(b['max_m'], ' m')}")
        print(f"   end of path off by {fmt(r.get('end_error_m'), ' m')}")
    if r.get("path_note"):
        print("   " + r["path_note"])
    m = r["measured"]
    print(f"   shooter spun up at {fmt(m['shooter_spun_up_s'], ' s')}, isShooting at {fmt(m['is_shooting_s'], ' s')}"
          + (f" ({r['shooter_spin_up_after_command_s']:+.2f} s after the export's shooter command)" if "shooter_spin_up_after_command_s" in r else ""))
    for mv in m["wrist_moves"]:
        print(f"   wrist {mv['from']:.3f} -> {mv['to']:.3f} rot from {mv['t0']:.2f} s, travel {mv['travel_s']:.2f} s")
    if "wrist_travel_model_s" in r:
        print(f"   wrist travel: model {r['wrist_travel_model_s']:.2f} s, measured {', '.join(f'{x:.2f}' for x in r['wrist_travel_measured_s'])} s")
    print("   export events: " + ", ".join(f"{e['name']} {e['t0']:.2f}-{e['t1']:.2f}" for e in r["events"]))


def compare(log_path: Path, autos_dir: Path, auto_name: str | None, alliance: str | None) -> list[dict]:
    log = read_log(log_path)
    commands = json.loads((APP / "data" / "auto_commands.json").read_text())
    return [compare_window(log, a, b, autos_dir, auto_name, alliance, commands) for a, b in auto_windows(log)]


class WpilogWriter:
    def __init__(self, path: Path) -> None:
        self.f = open(path, "wb")
        self.f.write(b"WPILOG" + struct.pack("<HI", 0x0100, 0))
        self.ids: dict[str, int] = {}

    def _record(self, entry: int, ts_us: int, payload: bytes) -> None:
        self.f.write(bytes([0x7F]) + struct.pack("<IIQ", entry, len(payload), ts_us) + payload)

    def _entry(self, name: str, typ: str) -> int:
        if name not in self.ids:
            self.ids[name] = len(self.ids) + 1
            nb, tb = name.encode(), typ.encode()
            self._record(0, 0, bytes([0]) + struct.pack("<II", self.ids[name], len(nb)) + nb
                         + struct.pack("<I", len(tb)) + tb + struct.pack("<I", 0))
        return self.ids[name]

    def write(self, name: str, typ: str, t: float, v) -> None:
        e = self._entry(name, typ)
        payload = {"boolean": lambda: bytes([1 if v else 0]), "double": lambda: struct.pack("<d", v),
                   "string": lambda: v.encode(), "struct:Pose2d": lambda: struct.pack("<3d", *v)}[typ]()
        self._record(e, int(t * 1e6), payload)

    def close(self) -> None:
        self.f.close()


def selftest() -> int:
    name = "Move Forward And Shoot Left"
    exp = json.loads((APP / "data" / "autos" / f"{name}.json").read_text())
    red = exp["samples"]["red"]
    dt = float(exp["dt"])
    lag, t0 = 0.12, 5.0
    rng = random.Random(1)
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "synthetic.wpilog"
        w = WpilogWriter(path)
        rk = "/RealOutputs/"
        w.write(rk + "PathPlanner/CurrentSelectedAuto", "string", 1.0, name)
        w.write("NT:/FMSInfo/IsRedAlliance", "boolean", 1.0, True)
        w.write("/DriverStation/Autonomous", "boolean", 1.0, True)
        w.write("/DriverStation/Enabled", "boolean", 1.0, False)
        w.write("/DriverStation/Enabled", "boolean", t0, True)
        n = len(red["x"])
        for k in range(int(25.0 / dt)):
            t = k * dt
            i = min(n - 1, max(0, round((t - lag) / dt)))
            pose = (red["x"][i] + rng.gauss(0, 0.01), red["y"][i] + rng.gauss(0, 0.01), red["heading"][i])
            w.write(rk + "Odometry/Robot", "struct:Pose2d", t0 + t, pose)
            wrist = 0.338 if t < 3.0 else max(0.0, 0.338 - (t - 3.0) * 0.338 / 0.8)
            w.write(rk + "IntakeSubsystem/WristPosition", "double", t0 + t, wrist)
            w.write(rk + "Shooter/IsSpunUp", "boolean", t0 + t, t > 4.0)
        w.write("/DriverStation/Enabled", "boolean", t0 + 20.0, False)
        w.close()
        results = compare(path, APP / "data" / "autos", None, None)
    for r in results:
        print_report(r)

    def check(cond: bool, what: str) -> None:
        if not cond:
            failures.append(what)

    check(len(results) == 1, f"one auto period, got {len(results)}")
    if results:
        r = results[0]
        check(r.get("auto") == name and r.get("alliance") == "red", "auto name and alliance from the log")
        check(abs(r.get("best_lag_s", 9) - lag) <= 0.021, f"best lag {r.get('best_lag_s')} ~ {lag}")
        check(r.get("path_at_best_lag", {}).get("rms_m", 9) < 0.03, "rms at the best lag is the noise floor")
        check(r.get("path", {}).get("rms_m", 0) > r.get("path_at_best_lag", {}).get("rms_m", 9), "lag raises the unaligned error")
        moves = r.get("measured", {}).get("wrist_moves", [])
        check(len(moves) == 1 and abs(moves[0]["travel_s"] - 0.8) < 0.05, f"one wrist move of 0.8 s: {moves}")
        check(abs((r["measured"].get("shooter_spun_up_s") or 0) - 4.0) <= 0.03, "shooter spun up at 4 s")
    for f in failures:
        print("FAIL " + f)
    print("selftest " + ("ok" if not failures else "failed"))
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", type=Path)
    ap.add_argument("--auto", help="auto to compare with (default: the one the log has selected)")
    ap.add_argument("--alliance", choices=["red", "blue"], help="default: from the log")
    ap.add_argument("--autos", type=Path, default=APP / "data" / "autos", help="export folder")
    ap.add_argument("--json", type=Path, help="write the results here")
    ap.add_argument("--selftest", action="store_true", help="compare a synthetic log made from the export")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.log is None:
        ap.error("a log file is required")
    results = compare(args.log, args.autos, args.auto, args.alliance)
    if not results:
        print(f"{args.log}: no enabled autonomous period in this log")
    for r in results:
        print_report(r)
    if args.json:
        args.json.write_text(json.dumps(results, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
