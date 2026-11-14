# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["robotpy-pathplannerlib==2026.1.2"]
#
# [tool.uv]
# exclude-newer = "2026-11-01T00:00:00Z"
# ///
"""Precompute every PathPlanner auto for the Godot dashboard.

Trajectories come from the official PathPlannerLib: the robot's own Java library
(2027) through java_trajectories.json, written by run_java_dump.sh, or the
robotpy port (2026) with --trajectories python. This script only walks the
.auto command tree, assigns time intervals by command-group semantics, and
resamples the library's trajectories with the library's own sample() on a
fixed grid. The Python library is always run as well, for the parity table.

Usage (from apps/comp-godot):
  uv run --script tools/pathplanner/export_autos.py [--trajectories auto|java|python]
      [--src DIR] [--out DIR] [--robot-src DIR] [--check]
"""

from __future__ import annotations

import argparse
import datetime as dt_mod
import hashlib
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field
from importlib import metadata
from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[2]
DEFAULT_SRC = APP_DIR / "data" / "pathplanner"
DEFAULT_OUT = APP_DIR / "data" / "autos"
DEFAULT_COMMANDS = APP_DIR / "data" / "auto_commands.json"
DEFAULT_JAVA_DUMP = APP_DIR / "tools" / "pathplanner" / "java_trajectories.json"
DEFAULT_ROBOT_SRC = Path.home() / "Developer" / "FIR" / "src" / "2026Rebuilt"

FORMAT_VERSION = 1
DT = 0.02
DIGITS = 7
POSE_TOL_M = 0.001
FLIP_TOL = 1e-6
VEL_TOL = 0.01
CHAIN_GAP_WARN_M = 0.05
PARITY_DURATION_TOL = 0.02
PARITY_POSE_TOL_M = 0.02
ROBOT_LIBRARY = {"name": "PathplannerLib-java", "version": "2027.0.0-alpha-4.1"}

INF = math.inf


def source_hash(src: Path) -> str:
    # AutoLibrary.source_hash() in core/auto/auto_library.gd must compute the same digest.
    entries = []
    for p in src.rglob("*"):
        rel = p.relative_to(src).as_posix()
        if p.is_file() and not any(part.startswith(".") for part in rel.split("/")):
            entries.append((rel, hashlib.sha256(p.read_bytes()).hexdigest()))
    entries.sort()
    h = hashlib.sha256()
    for rel, digest in entries:
        h.update(f"{rel}\n{digest}\n".encode())
    return h.hexdigest()


def file_hash(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def r(v: float) -> float:
    out = round(float(v), DIGITS)
    return 0.0 if out == 0 else out


def wrap_angle(a: float) -> float:
    return math.atan2(math.sin(a), math.cos(a))


def angle_diff(a: float, b: float) -> float:
    return abs(wrap_angle(a - b))


def load_library(deploy_parent: Path):
    import pathplannerlib.config as pp_config
    import pathplannerlib.path as pp_path

    pp_path.getDeployDirectory = lambda: str(deploy_parent)
    pp_config.getDeployDirectory = lambda: str(deploy_parent)

    from pathplannerlib.config import RobotConfig
    from pathplannerlib.events import OneShotTriggerEvent, TriggerEvent
    from pathplannerlib.path import PathPlannerPath
    from pathplannerlib.trajectory import PathPlannerTrajectory, PathPlannerTrajectoryState
    from pathplannerlib.util import DriveFeedforwards, FlippingUtil
    from wpimath.geometry import Pose2d, Rotation2d
    from wpimath.kinematics import ChassisSpeeds

    return {
        "RobotConfig": RobotConfig,
        "PathPlannerPath": PathPlannerPath,
        "PathPlannerTrajectory": PathPlannerTrajectory,
        "PathPlannerTrajectoryState": PathPlannerTrajectoryState,
        "TriggerEvent": TriggerEvent,
        "OneShotTriggerEvent": OneShotTriggerEvent,
        "DriveFeedforwards": DriveFeedforwards,
        "FlippingUtil": FlippingUtil,
        "Pose2d": Pose2d,
        "Rotation2d": Rotation2d,
        "ChassisSpeeds": ChassisSpeeds,
    }


def java_trajectory(lib, d: dict, num_modules: int):
    # Rebuilt as robotpy objects so the library's own sample() interpolates (same algorithm as Java's).
    states = []
    for i in range(len(d["t"])):
        st = lib["PathPlannerTrajectoryState"]()
        st.timeSeconds = d["t"][i]
        st.pose = lib["Pose2d"](d["x"][i], d["y"][i], lib["Rotation2d"](d["rot"][i]))
        st.fieldSpeeds = lib["ChassisSpeeds"](d["vx"][i], d["vy"][i], d["omega"][i])
        st.linearVelocity = d["linear_velocity"][i]
        st.heading = lib["Rotation2d"](d["heading"][i])
        st.feedforwards = lib["DriveFeedforwards"].zeros(num_modules)
        states.append(st)
    events = []
    for e in d["events"]:
        if e["type"] == "trigger":
            events.append(lib["TriggerEvent"](e["t"], e["name"], e["active"]))
        elif e["type"] == "one_shot":
            events.append(lib["OneShotTriggerEvent"](e["t"], e["name"]))
        else:
            raise ValueError(f"unsupported Java trajectory event {e}")
    return lib["PathPlannerTrajectory"](None, None, None, None, states, events)


def robot_registered_names(robot_src: Path | None) -> tuple[set[str] | None, set[str] | None]:
    if robot_src is None:
        return None, None
    java_root = robot_src / "src" / "main" / "java"
    container = java_root / "frc" / "robot" / "RobotContainer.java"
    if not container.is_file():
        return None, None
    registered = set(re.findall(r'NamedCommands\.registerCommand\(\s*"([^"]+)"', container.read_text()))
    triggers: set[str] = set()
    for java in java_root.rglob("*.java"):
        triggers.update(re.findall(r'EventTrigger\(\s*"([^"]+)"', java.read_text(errors="replace")))
    return registered, triggers


@dataclass
class TrajInfo:
    name: str
    traj: object
    flipped: object
    duration: float
    max_velocity: float
    kind: str
    markers: list = field(default_factory=list)


class Planner:
    def __init__(self, lib, src: Path, java_dump: dict | None = None):
        self.lib = lib
        self.src = src
        self.config = lib["RobotConfig"].fromGUISettings()
        self.path_cache: dict[str, object] = {}
        self.java = {p["name"]: p for p in java_dump["paths"]} if java_dump else None
        self.java_cache: dict[tuple[str, str], object] = {}

    def ideal(self, name: str, path, side: str):
        if self.java is None:
            return path.getIdealTrajectory(self.config)
        key = (name, side)
        if key not in self.java_cache:
            self.java_cache[key] = java_trajectory(self.lib, self.java[name][side], self.config.numModules)
        return self.java_cache[key]

    def regenerate(self, name: str, path, speeds, rotation):
        if self.java is not None:
            raise RuntimeError(
                f"'{name}' starts away from its ideal starting state, so the robot regenerates its trajectory; "
                "java_trajectories.json only holds ideal trajectories. Extend TrajectoryDump.java for this case."
            )
        return path.generateTrajectory(speeds, rotation, self.config)

    def path(self, name: str):
        if name not in self.path_cache:
            self.path_cache[name] = self.lib["PathPlannerPath"].fromPathFile(name)
        return self.path_cache[name]

    def raw_path(self, name: str) -> dict:
        return json.loads((self.src / "paths" / f"{name}.path").read_text())

    def _follow(self, name: str, path, side: str, pose, speeds):
        # Mirrors FollowPathCommand.initialize: the ideal trajectory when the robot is near the ideal start state.
        ideal = path.getIdealStartingState()
        if ideal is not None and pose is not None:
            lin = math.hypot(speeds.vx, speeds.vy)
            ideal_vel = abs(lin - ideal.velocity) <= 0.25
            ideal_rot = (not self.config.isHolonomic) or abs((pose.rotation() - ideal.rotation).degrees()) <= 30.0
            if ideal_vel and ideal_rot:
                return self.ideal(name, path, side), "ideal"
            return self.regenerate(name, path, speeds, pose.rotation()), "regenerated"
        if ideal is not None:
            return self.ideal(name, path, side), "ideal"
        rot = pose.rotation() if pose is not None else path.getStartingHolonomicPose().rotation()
        return self.regenerate(name, path, speeds, rot), "regenerated"

    def follow(self, name: str, red_state) -> TrajInfo:
        cs = self.lib["ChassisSpeeds"]
        path = self.path(name)
        pose, speeds = red_state if red_state is not None else (None, cs())
        traj, kind = self._follow(name, path, "red", pose, speeds)
        flipped_path = path.flipPath()
        fpose = self.lib["FlippingUtil"].flipFieldPose(pose) if pose is not None else None
        ftraj, fkind = self._follow(name, flipped_path, "blue", fpose, speeds)
        if fkind != kind:
            raise AssertionError(f"{name}: red uses the {kind} trajectory but blue the {fkind} one")
        return TrajInfo(
            name=name,
            traj=traj,
            flipped=ftraj,
            duration=traj.getTotalTimeSeconds(),
            max_velocity=path.getGlobalConstraints().maxVelocityMps,
            kind=kind,
            markers=self.raw_path(name).get("eventMarkers", []),
        )

    @staticmethod
    def end_state(info: TrajInfo):
        end = info.traj.getEndState()
        rr = type(end.fieldSpeeds).fromFieldRelativeSpeeds(end.fieldSpeeds, end.pose.rotation())
        return end.pose, rr


def wrist_command_length(commands: dict) -> float:
    wrist = commands["wrist"]
    mode = wrist["at_setpoint_check"]
    if mode == "always_true":
        return float(commands["robot_loop_s"])
    if mode == "tolerance":
        return float(wrist["travel_s"])
    raise ValueError(f"unknown wrist at_setpoint_check {mode!r}")


class Timeline:
    def __init__(self, planner: Planner, commands: dict, registered: set[str], triggers: set[str], auto_len: float):
        self.planner = planner
        self.commands = commands
        self.registered = registered
        self.triggers = triggers
        self.auto_len = auto_len
        self.paths: list[dict] = []
        self.events: list[dict] = []
        self.warnings: list[dict] = []
        self.robot_state = None
        self._warned: set[tuple[str, str]] = set()

    def warn(self, code: str, name: str, message: str) -> None:
        if (code, name) in self._warned:
            return
        self._warned.add((code, name))
        self.warnings.append({"code": code, "name": name, "message": message})

    def command_end(self, name: str) -> tuple[float, str]:
        spec = self.commands["commands"].get(name)
        if name not in self.registered:
            self.warn(
                "unregistered_command",
                name,
                f"'{name}' is not registered with NamedCommands in the robot code; PathPlannerLib runs Commands.none() (an instant no-op).",
            )
            return 0.0, "noop"
        if spec is None:
            self.warn("no_end_model", name, f"'{name}' has no end model in auto_commands.json; treated as instant.")
            return 0.0, "self"
        end = spec["end"]
        if end == "never":
            return INF, "never"
        if end == "wrist_at_setpoint":
            return wrist_command_length(self.commands), "self"
        if end == "instant":
            return 0.0, "self"
        raise ValueError(f"unknown end model {end!r} for {name}")

    def run(self, node: dict, t0: float) -> tuple[float, list[dict]]:
        kind = node["type"]
        data = node.get("data", {})
        items: list[dict] = []
        if kind == "path":
            name = data["pathName"]
            info = self.planner.follow(name, self.robot_state)
            seg = {"type": "path", "name": name, "t0": t0, "t1": t0 + info.duration, "info": info, "end_reason": "self"}
            self.paths.append(seg)
            items.append(seg)
            self.robot_state = Planner.end_state(info)
            items.extend(self.path_markers(info, t0))
            return t0 + info.duration, items
        if kind == "named":
            name = data["name"]
            length, reason = self.command_end(name)
            ev = {
                "name": name,
                "kind": "noop" if reason == "noop" else "command",
                "t0": t0,
                "t1": t0 + length,
                "end_reason": reason if reason != "noop" else "self",
                "source": "auto",
                "registered": name in self.registered,
            }
            self.events.append(ev)
            items.append(ev)
            return t0 + length, items
        if kind == "wait":
            return t0 + float(data["waitTime"]), items
        if kind == "sequential":
            t = t0
            for i, child in enumerate(data["commands"]):
                if math.isinf(t):
                    skipped = [c.get("data", {}).get("name") or c.get("data", {}).get("pathName") or c["type"] for c in data["commands"][i:]]
                    self.warn("unreachable_commands", ",".join(skipped), f"never reached after a command that does not end: {skipped}")
                    break
                t, sub = self.run(child, t)
                items.extend(sub)
            return t, items
        if kind in ("parallel", "deadline", "race"):
            ends = []
            subs = []
            for child in data["commands"]:
                e, sub = self.run(child, t0)
                ends.append(e)
                subs.append(sub)
                items.extend(sub)
            if sum(1 for s in subs for it in s if it.get("type") == "path") > 1:
                self.warn("parallel_paths", kind, f"{kind} group runs more than one path at once; the drive requirement makes this invalid")
            if kind == "parallel":
                end = max(ends) if ends else t0
            elif kind == "deadline":
                end = ends[0] if ends else t0
            else:
                end = min(ends) if ends else t0
            if not math.isinf(end):
                for it in items:
                    if it["t1"] > end:
                        it["t1"] = end
                        it["end_reason"] = "deadline" if kind == "deadline" else "race"
            return end, items
        raise ValueError(f"unsupported command type {kind!r}")

    def path_markers(self, info: TrajInfo, t0: float) -> list[dict]:
        trig_cls = self.planner.lib["TriggerEvent"]
        one_cls = self.planner.lib["OneShotTriggerEvent"]
        starts: dict[str, list[float]] = {}
        stops: dict[str, list[float]] = {}
        shots: dict[str, list[float]] = {}
        for e in info.traj.getEvents():
            if isinstance(e, trig_cls):
                (starts if e._active else stops).setdefault(e._name, []).append(e.getTimestamp())
            elif isinstance(e, one_cls):
                shots.setdefault(e._name, []).append(e.getTimestamp())
        out = []
        for m in info.markers:
            name = m["name"]
            zoned = m.get("endWaypointRelativePos") is not None and m["endWaypointRelativePos"] >= 0
            cmd = m.get("command")
            cmd_name = cmd["data"]["name"] if cmd and cmd.get("type") == "named" else None
            bound = name in self.triggers
            if zoned:
                a = starts[name].pop(0)
                b = stops[name].pop(0)
            else:
                a = b = shots[name].pop(0)
            ev = {
                "name": name,
                "kind": "zone_marker" if zoned else "marker",
                "t0": t0 + a,
                "t1": t0 + b,
                "end_reason": "self",
                "source": f"path:{info.name}",
                "registered": name in self.registered,
                "command": cmd_name,
                "trigger_bound": bound,
            }
            self.events.append(ev)
            out.append(ev)
            if cmd_name is None and not bound:
                self.warn(
                    "unbound_marker",
                    name,
                    f"Event marker '{name}' in '{info.name}' has no command and the robot binds no EventTrigger('{name}'), so nothing runs there.",
                )
            if cmd_name is not None:
                length, reason = self.command_end(cmd_name)
                end = t0 + b if zoned else t0 + a + length
                end = min(end, t0 + info.duration, t0 + a + length)
                cev = {
                    "name": cmd_name,
                    "kind": "noop" if reason == "noop" else "command",
                    "t0": t0 + a,
                    "t1": end,
                    "end_reason": "self",
                    "source": f"marker:{info.name}:{name}",
                    "registered": cmd_name in self.registered,
                }
                self.events.append(cev)
                out.append(cev)
        return out


def pose_triplet(pose) -> list[float]:
    return [pose.X(), pose.Y(), pose.rotation().radians()]


def flip_triplet(lib, p: list[float]) -> list[float]:
    fu = lib["FlippingUtil"]
    return [fu.fieldSizeX - p[0], fu.fieldSizeY - p[1], wrap_angle(p[2] + math.pi)]


def sample_auto(segments: list[dict], duration: float) -> dict | None:
    if not segments:
        return None
    n = int(math.floor(duration / DT + 1e-9)) + 1
    out = {}
    for side in ("red", "blue"):
        ch = {k: [] for k in ("x", "y", "heading", "vx", "vy", "omega")}
        for k in range(n):
            t = k * DT
            seg = next((s for s in segments if s["t0"] <= t <= s["t1"]), segments[-1])
            if seg["type"] == "path":
                info = seg["info"]
                traj = info.traj if side == "red" else info.flipped
                st = traj.sample(t - seg["t0"])
                vals = (st.pose.X(), st.pose.Y(), st.pose.rotation().radians(), st.fieldSpeeds.vx, st.fieldSpeeds.vy, st.fieldSpeeds.omega)
            else:
                p = seg["pose"][side]
                vals = (p[0], p[1], p[2], 0.0, 0.0, 0.0)
            for key, v in zip(("x", "y", "heading", "vx", "vy", "omega"), vals):
                ch[key].append(r(v))
        out[side] = ch
    return out


def build_segments(paths: list[dict], duration: float, start_pose: dict | None, lib) -> list[dict]:
    if not paths:
        return []
    segs = []
    t = 0.0
    pose = start_pose
    for p in paths:
        if p["t0"] > t + 1e-9:
            segs.append({"type": "hold", "t0": t, "t1": p["t0"], "pose": pose})
        segs.append(p)
        info = p["info"]
        red_end = pose_triplet(info.traj.sample(p["t1"] - p["t0"]).pose)
        blue_end = pose_triplet(info.flipped.sample(p["t1"] - p["t0"]).pose)
        pose = {"red": red_end, "blue": blue_end}
        t = p["t1"]
    if duration > t + 1e-9:
        segs.append({"type": "hold", "t0": t, "t1": duration, "pose": pose})
    return segs


def export_auto(name: str, auto_json: dict, planner: Planner, commands: dict, registered: set[str], triggers: set[str]) -> dict:
    lib = planner.lib
    auto_len = float(commands["auto_length_s"])
    tl = Timeline(planner, commands, registered, triggers, auto_len)
    tree_end, _ = tl.run(auto_json["command"], 0.0)

    ends_by_itself = not math.isinf(tree_end)
    for ev in tl.events:
        if math.isinf(ev["t1"]):
            ev["t1"] = auto_len
            ev["end_reason"] = "auto_end"
    finite_ends = [p["t1"] for p in tl.paths] + [e["t1"] for e in tl.events if e["end_reason"] != "auto_end"]
    if ends_by_itself:
        finite_ends.append(tree_end)
    duration = max(finite_ends, default=0.0)
    truncated = duration > auto_len + 1e-9
    if truncated:
        tl.warn("truncated_at_auto_end", name, f"timeline runs {duration:.2f} s, past the {auto_len:.0f} s auto period")
        duration = auto_len
        for item in tl.paths + tl.events:
            item["t1"] = min(item["t1"], auto_len)

    start_pose = None
    end_pose = None
    if tl.paths:
        first = tl.paths[0]["info"]
        last = tl.paths[-1]["info"]
        start_pose = {"red": pose_triplet(first.traj.getInitialState().pose), "blue": pose_triplet(first.flipped.getInitialState().pose)}
        end_pose = {"red": pose_triplet(last.traj.getEndState().pose), "blue": pose_triplet(last.flipped.getEndState().pose)}
        for a, b in zip(tl.paths, tl.paths[1:]):
            gap = math.dist(pose_triplet(a["info"].traj.getEndState().pose)[:2], pose_triplet(b["info"].traj.getInitialState().pose)[:2])
            if gap > CHAIN_GAP_WARN_M:
                tl.warn("chain_gap", b["name"], f"'{b['name']}' starts {gap:.3f} m from the end of '{a['name']}'")

    nominal = duration
    if tl.paths:
        duration = min(math.ceil(nominal / DT - 1e-9) * DT, auto_len)
    segments = build_segments(tl.paths, duration, start_pose, lib)
    samples = sample_auto(segments, duration)
    check_auto(name, duration, segments, samples, start_pose, end_pose, lib)

    def seg_out(s: dict) -> dict:
        if s["type"] == "path":
            info = s["info"]
            return {
                "type": "path",
                "name": s["name"],
                "t0": r(s["t0"]),
                "t1": r(s["t1"]),
                "path_duration_s": r(info.duration),
                "max_velocity_mps": r(info.max_velocity),
                "trajectory": info.kind,
                "truncated": s["t1"] < s["t0"] + info.duration - 1e-9,
            }
        return {"type": "hold", "t0": r(s["t0"]), "t1": r(s["t1"])}

    events = sorted(tl.events, key=lambda e: (e["t0"], e["source"], e["name"]))
    return {
        "version": FORMAT_VERSION,
        "name": name,
        "folder": auto_json.get("folder"),
        "dt": DT,
        "duration_s": r(duration),
        "nominal_duration_s": r(nominal),
        "auto_length_s": auto_len,
        "ends_by_itself": ends_by_itself,
        "truncated_at_auto_end": truncated,
        "sample_count": len(samples["red"]["x"]) if samples is not None else 0,
        "start_pose": None if start_pose is None else {k: [r(v) for v in vals] for k, vals in start_pose.items()},
        "end_pose": None if end_pose is None else {k: [r(v) for v in vals] for k, vals in end_pose.items()},
        "paths": [p["name"] for p in tl.paths],
        "samples": samples if samples is not None else {"red": None, "blue": None},
        "segments": [seg_out(s) for s in segments],
        "events": [
            {k: (r(v) if k in ("t0", "t1") else v) for k, v in ev.items()}
            for ev in events
        ],
        "warnings": tl.warnings,
    }


def check_auto(name, duration, segments, samples, start_pose, end_pose, lib) -> None:
    if not segments:
        assert start_pose is None and samples is None, f"{name}: no path but samples exist"
        return
    red, blue = samples["red"], samples["blue"]
    n = len(red["x"])
    assert n == math.floor(duration / DT + 1e-9) + 1, f"{name}: {n} samples for {duration} s"
    for side in ("red", "blue"):
        s = samples[side]
        p0 = [s["x"][0], s["y"][0], s["heading"][0]]
        p1 = [s["x"][-1], s["y"][-1], s["heading"][-1]]
        assert math.dist(p0[:2], start_pose[side][:2]) <= POSE_TOL_M, f"{name}/{side}: first sample {p0} != start {start_pose[side]}"
        assert math.dist(p1[:2], end_pose[side][:2]) <= POSE_TOL_M, f"{name}/{side}: last sample {p1} != end {end_pose[side]}"
        assert angle_diff(p0[2], start_pose[side][2]) <= 1e-3 and angle_diff(p1[2], end_pose[side][2]) <= 1e-3, f"{name}/{side}: heading"
    for k in range(n):
        f = flip_triplet(lib, [red["x"][k], red["y"][k], red["heading"][k]])
        assert abs(blue["x"][k] - f[0]) <= FLIP_TOL and abs(blue["y"][k] - f[1]) <= FLIP_TOL, f"{name}: flip pos at {k}"
        assert angle_diff(blue["heading"][k], f[2]) <= FLIP_TOL, f"{name}: flip heading at {k}"
        assert abs(blue["vx"][k] + red["vx"][k]) <= FLIP_TOL and abs(blue["vy"][k] + red["vy"][k]) <= FLIP_TOL, f"{name}: flip vel at {k}"
        assert abs(blue["omega"][k] - red["omega"][k]) <= FLIP_TOL, f"{name}: flip omega at {k}"
    for seg in segments:
        if seg["type"] != "path":
            continue
        vmax = seg["info"].max_velocity * (1 + VEL_TOL)
        k0 = math.ceil(seg["t0"] / DT - 1e-9)
        k1 = min(n - 1, math.floor(seg["t1"] / DT + 1e-9))
        for k in range(k0, k1 + 1):
            speed = math.hypot(red["vx"][k], red["vy"][k])
            assert speed <= vmax, f"{name}: {speed:.3f} m/s at t={k * DT:.2f} exceeds {seg['name']} max {seg['info'].max_velocity}"


def check_timeline(auto: dict) -> None:
    dur = auto["duration_s"]
    for ev in auto["events"]:
        assert 0 <= ev["t0"] <= ev["t1"] <= auto["auto_length_s"] + 1e-9, f"{auto['name']}: bad interval {ev}"
        if ev["end_reason"] != "auto_end":
            assert ev["t1"] <= dur + 1e-6, f"{auto['name']}: {ev['name']} ends after the nominal duration"
    segs = auto["segments"]
    if segs:
        assert segs[0]["t0"] == 0.0 and abs(segs[-1]["t1"] - dur) < 1e-6, f"{auto['name']}: segments do not cover [0, duration]"
        for a, b in zip(segs, segs[1:]):
            assert abs(a["t1"] - b["t0"]) < 1e-6, f"{auto['name']}: segment gap {a} {b}"


def path_summaries(planner: Planner, py_planner: Planner, src: Path, used_by: dict[str, list[str]]) -> list[dict]:
    out = []
    for f in sorted((src / "paths").glob("*.path")):
        name = f.stem
        info = planner.follow(name, None)
        py = py_planner.follow(name, None)
        out.append({
            "name": name,
            "duration_s": r(info.duration),
            "python_duration_s": r(py.duration),
            "states": len(info.traj.getStates()),
            "max_velocity_mps": r(info.max_velocity),
            "start_pose": [r(v) for v in pose_triplet(info.traj.getInitialState().pose)],
            "end_pose": [r(v) for v in pose_triplet(info.traj.getEndState().pose)],
            "python_end_pose": [r(v) for v in pose_triplet(py.traj.getEndState().pose)],
            "events": [type(e).__name__ for e in info.traj.getEvents()],
            "used_by": sorted(used_by.get(name, [])),
        })
    return out


def parity_block(py_planner: Planner, src: Path, dump: dict | None, paths_hash: str) -> dict | None:
    if dump is None:
        return None
    java = {p["name"]: p for p in dump["paths"]}
    rows = []
    ok = True
    for f in sorted((src / "paths").glob("*.path")):
        name = f.stem
        py = py_planner.follow(name, None)
        py_end = pose_triplet(py.traj.getEndState().pose)
        j = java.get(name)
        if j is None:
            rows.append({"name": name, "ok": False, "missing": True})
            ok = False
            continue
        red = j["red"]
        j_end = [red["x"][-1], red["y"][-1], red["rot"][-1]]
        dur_rel = abs(py.duration - j["duration_s"]) / max(j["duration_s"], 1e-9)
        end_err = math.dist(py_end[:2], j_end[:2])
        row_ok = dur_rel <= PARITY_DURATION_TOL and end_err <= PARITY_POSE_TOL_M
        ok &= row_ok
        rows.append({
            "name": name,
            "python_duration_s": r(py.duration),
            "java_duration_s": r(j["duration_s"]),
            "duration_rel_diff": r(dur_rel),
            "end_pose_diff_m": r(end_err),
            "end_heading_diff_rad": r(angle_diff(py_end[2], j_end[2])),
            "ok": row_ok,
        })
    return {
        "python_library": {"name": "robotpy-pathplannerlib", "version": metadata.version("robotpy-pathplannerlib")},
        "java_library": dump["library"],
        "dumped_at": dump.get("dumped_at"),
        "stale": dump.get("paths_hash") != paths_hash,
        "tolerance": {"duration_rel": PARITY_DURATION_TOL, "end_pose_m": PARITY_POSE_TOL_M},
        "ok": ok,
        "decision": "Java trajectories are exported (python and java disagree)" if not ok else "python and java agree",
        "rows": rows,
    }


def dumps(obj) -> str:
    return json.dumps(obj, indent=1, ensure_ascii=False, allow_nan=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=DEFAULT_SRC, help="raw PathPlanner dir (autos/, paths/, settings.json)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--commands", type=Path, default=DEFAULT_COMMANDS)
    ap.add_argument("--java-dump", type=Path, default=DEFAULT_JAVA_DUMP, help="written by run_java_dump.sh")
    ap.add_argument(
        "--trajectories",
        choices=("auto", "java", "python"),
        default="auto",
        help="auto: the Java dump, which must match data/pathplanner/paths (python parity failed, see index.json)",
    )
    ap.add_argument("--robot-src", type=Path, default=Path(os.environ.get("FIR_ROBOT_SRC", DEFAULT_ROBOT_SRC)))
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if --out differs from a fresh export")
    args = ap.parse_args()

    src = args.src.resolve()
    if src.name != "pathplanner":
        print(f"--src must be a directory named 'pathplanner' (got {src})", file=sys.stderr)
        return 2
    lib = load_library(src.parent)
    py_planner = Planner(lib, src)
    paths_hash = source_hash(src / "paths")
    java_dump = json.loads(args.java_dump.read_text()) if args.java_dump.is_file() else None
    java_fresh = java_dump is not None and java_dump.get("paths_hash") == paths_hash
    if args.trajectories in ("auto", "java") and not java_fresh:
        why = "missing" if java_dump is None else "stale (data/pathplanner/paths changed since it was dumped)"
        print(
            f"{args.java_dump} is {why}. Run tools/pathplanner/run_java_dump.sh (needs the FIR scratch copy), "
            "or pass --trajectories python to export the robotpy trajectories, which differ from the robot's Java library.",
            file=sys.stderr,
        )
        return 1
    use_java = args.trajectories != "python"
    planner = Planner(lib, src, java_dump) if use_java else py_planner
    if use_java:
        trajectory_library = {"provider": "java", **java_dump["library"], "dumped_at": java_dump.get("dumped_at")}
    else:
        trajectory_library = {"provider": "python", "name": "robotpy-pathplannerlib", "version": metadata.version("robotpy-pathplannerlib")}
    commands = json.loads(args.commands.read_text())

    fir_registered, fir_triggers = robot_registered_names(args.robot_src)
    json_registered = {n for n, c in commands["commands"].items() if c.get("registered")}
    if fir_registered is not None:
        registered, triggers, reg_source = fir_registered, fir_triggers, "robot_code"
        if fir_registered != json_registered:
            print(f"warning: auto_commands.json registered set {sorted(json_registered)} differs from RobotContainer {sorted(fir_registered)}", file=sys.stderr)
    else:
        registered, triggers, reg_source = json_registered, set(commands.get("bound_event_triggers", [])), "auto_commands.json"

    fu = lib["FlippingUtil"]
    auto_files = sorted((src / "autos").glob("*.auto"))
    autos = []
    used_by: dict[str, list[str]] = {}
    for f in auto_files:
        auto = export_auto(f.stem, json.loads(f.read_text()), planner, commands, registered, triggers)
        check_timeline(auto)
        autos.append(auto)
        for p in auto["paths"]:
            used_by.setdefault(p, []).append(auto["name"])

    paths = path_summaries(planner, py_planner, src, used_by)
    s_hash = source_hash(src)
    c_hash = file_hash(args.commands)
    index = {
        "version": FORMAT_VERSION,
        "generator": "tools/pathplanner/export_autos.py",
        "trajectory_library": trajectory_library,
        "robot_library": ROBOT_LIBRARY,
        "source_hash": s_hash,
        "commands_hash": c_hash,
        "paths_hash": paths_hash,
        "exported_at": None,
        "registered_commands": sorted(registered),
        "registered_source": reg_source,
        "field": {"length_m": fu.fieldSizeX, "width_m": fu.fieldSizeY, "symmetry": "rotational"},
        "frame": "WPILib blue-origin field meters, heading in radians CCW; 'red' is the authored path, 'blue' the PathPlannerLib flip",
        "dt": DT,
        "auto_length_s": float(commands["auto_length_s"]),
        "autos": [
            {
                "name": a["name"],
                "file": f"{a['name']}.json",
                "folder": a["folder"],
                "duration_s": a["duration_s"],
                "sample_count": a["sample_count"],
                "has_path": bool(a["paths"]),
                "paths": a["paths"],
                "ends_by_itself": a["ends_by_itself"],
                "warnings": sorted({w["code"] for w in a["warnings"]}),
            }
            for a in autos
        ],
        "paths": paths,
        "parity": parity_block(py_planner, src, java_dump, paths_hash),
    }

    out = args.out
    files = {f"{a['name']}.json": dumps(a) for a in autos}
    prev_index = out / "index.json"
    prev = json.loads(prev_index.read_text()) if prev_index.is_file() else {}
    index_core = dict(index)
    prev_core = dict(prev)
    prev_core.pop("exported_at", None)
    index_core.pop("exported_at", None)
    unchanged = prev_core == json.loads(dumps(index_core)) and all(
        (out / n).is_file() and (out / n).read_text() == body for n, body in files.items()
    )
    stale_files = sorted(p.name for p in out.glob("*.json") if p.name != "index.json" and p.name not in files) if out.is_dir() else []
    if unchanged and prev.get("exported_at"):
        index["exported_at"] = prev["exported_at"]
    else:
        index["exported_at"] = dt_mod.datetime.now(dt_mod.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    summary = ", ".join(f"{a['name']} {a['duration_s']:.2f}s/{a['sample_count']}" for a in autos)
    if args.check:
        if unchanged and not stale_files:
            print(f"up to date: {len(autos)} autos, {len(paths)} paths")
            return 0
        print(f"export is stale under {out} (extra files: {stale_files})", file=sys.stderr)
        return 1

    out.mkdir(parents=True, exist_ok=True)
    for n in stale_files:
        (out / n).unlink()
    for n, body in files.items():
        tmp = out / (n + ".tmp")
        tmp.write_text(body)
        tmp.replace(out / n)
    tmp = out / "index.json.tmp"
    tmp.write_text(dumps(index))
    tmp.replace(prev_index)
    parity = index["parity"]
    parity_note = "no Java parity dump" if parity is None else f"java parity ok={parity['ok']} stale={parity['stale']}"
    print(f"exported {len(autos)} autos, {len(paths)} paths to {out} ({'unchanged' if unchanged else 'updated'}; {parity_note})")
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
