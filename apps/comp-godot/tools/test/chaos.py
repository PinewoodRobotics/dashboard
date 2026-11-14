# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["pyntcore==2026.2.2"]
# ///
"""Chaos run: the dashboard (both windows) stays up while the fake robot is
killed and restarted at random times. Every restart must bring the app back
to READY within 6 s of the robot listening again (from the app's --nt-trace),
and the robot's State topics must show the stored auto selection and intake
override again (seen by an independent NT client), with no user action.

Usage: uv run tools/test/chaos.py --app APP --godot GODOT --work DIR [--restarts 10] [--seed N]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import ntcore

AUTO = "Move Forward And Shoot Left"
INTAKE = 0.37
AUTO_STATE = "/Shared/PathPlanner/SelectedPath/State"
INTAKE_STATE = "/Shared/Intake/Speed/State"
READY_BUDGET_S = 6.0


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


class FakeRobot:
    def __init__(self, app: Path, work: Path, port: int, tag: str):
        self.cmd = ["uv", "run", "--quiet", "--script", str(app / "tools/sim/fake_robot.py"), "--port", str(port),
                    "--pid-file", str(work / "chaos_robot.pid"), "--tag", tag, "--alliance", "red", "--pose", "13,4,3.14"]
        self.port = port
        self.pid_file = work / "chaos_robot.pid"
        self.log = open(work / "chaos_robot.log", "a")
        self.proc: subprocess.Popen | None = None

    def start(self) -> float:
        self.pid_file.unlink(missing_ok=True)
        self.proc = subprocess.Popen(self.cmd, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 20
        while time.time() < deadline:
            if listening(self.port):
                return time.time()
            time.sleep(0.02)
        raise RuntimeError("fake robot did not start")

    def kill(self, sig: int) -> None:
        pid = int(self.pid_file.read_text().strip())
        os.kill(pid, sig)
        if self.proc:
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.kill(pid, signal.SIGKILL)
                self.proc.wait(timeout=5)
        while listening(self.port):
            time.sleep(0.02)


def trace_ready_after(trace: Path, t: float) -> float | None:
    if not trace.exists():
        return None
    for line in trace.read_text().splitlines():
        e = json.loads(line)
        if e["state"] == "READY" and e["unix"] > t:
            return e["unix"]
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--godot", default="godot")
    ap.add_argument("--work", required=True)
    ap.add_argument("--restarts", type=int, default=10)
    ap.add_argument("--seed", type=int, default=int(time.time()))
    args = ap.parse_args()
    app, work = Path(args.app), Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    print(f"chaos: {args.restarts} restarts, seed {args.seed}")

    port = free_port()
    tag = f"comp-godot-chaos-{os.getpid()}"
    robot = FakeRobot(app, work, port, tag)
    settings = work / "chaos_settings.json"
    settings.write_text(json.dumps({"controls": {"selected_auto": AUTO, "intake_speed": INTAKE}}))
    trace = work / "chaos_nt_trace.jsonl"
    quit_file = work / "chaos.quit"
    trace.unlink(missing_ok=True)
    quit_file.unlink(missing_ok=True)
    env = dict(os.environ, PWRUP_SHARED_SETTINGS_PATH=str(work / "chaos_connection.json"))
    robot.start()
    app_log = open(work / "chaos_app.log", "w")
    app_proc = subprocess.Popen(
        [args.godot, "--path", str(app), "--", "--screen=both", "--live", "--nt-host=127.0.0.1", f"--nt-port={port}",
         f"--settings={settings}", f"--nt-trace={trace}", f"--quit-file={quit_file}", "--frames=10", "--run-s=900",
         f"--report={work / 'chaos_app.json'}"],
        stdout=app_log, stderr=subprocess.STDOUT, env=env)

    inst = ntcore.NetworkTableInstance.create()
    inst.startClient4("chaos-observer")
    inst.setServer("127.0.0.1", port)
    auto_sub = inst.getStringTopic(AUTO_STATE).subscribe("", ntcore.PubSubOptions(keepDuplicates=True, pollStorage=32))
    intake_sub = inst.getDoubleTopic(INTAKE_STATE).subscribe(-2.0, ntcore.PubSubOptions(keepDuplicates=True, pollStorage=32))

    def restored(t_listen: float, timeout: float) -> float | None:
        auto_ok = intake_ok = False
        deadline = t_listen + timeout
        while time.time() < deadline:
            for v in auto_sub.readQueue():
                auto_ok = v.value == AUTO
            for v in intake_sub.readQueue():
                intake_ok = abs(v.value - INTAKE) < 1e-9
            if auto_ok and intake_ok:
                return time.time() - t_listen
            time.sleep(0.01)
        return None

    failures: list[str] = []
    results = []
    try:
        first = restored(time.time(), 30.0)
        if first is None:
            failures.append("stored selection and intake never reached the robot after launch")
        print(f"launch: robot State shows {AUTO!r} and {INTAKE} ({'never' if first is None else f'{first:.2f} s'})")
        for i in range(args.restarts):
            time.sleep(rng.uniform(2.0, 8.0))
            sig = rng.choice([signal.SIGKILL, signal.SIGTERM])
            down_s = rng.uniform(0.2, 4.0)
            auto_sub.readQueue()
            intake_sub.readQueue()
            t_kill = time.time()
            robot.kill(sig)
            time.sleep(down_s)
            t_listen = robot.start()
            back = restored(t_listen, 10.0)
            ready_at = None
            deadline = t_listen + 10.0
            while time.time() < deadline:
                ready_at = trace_ready_after(trace, t_kill)
                if ready_at is not None:
                    break
                time.sleep(0.05)
            ready_s = None if ready_at is None else ready_at - t_listen
            ok = ready_s is not None and ready_s <= READY_BUDGET_S and back is not None and back <= READY_BUDGET_S
            results.append({"restart": i + 1, "signal": signal.Signals(sig).name, "down_s": round(down_s, 2),
                            "ready_s": None if ready_s is None else round(ready_s, 3),
                            "restored_s": None if back is None else round(back, 3), "ok": ok})
            print(f"{'ok  ' if ok else 'FAIL'} restart {i + 1:2d}: {signal.Signals(sig).name:7s} down {down_s:4.2f} s, "
                  f"READY {('never' if ready_s is None else f'{ready_s:5.2f} s')} after the robot listens, "
                  f"auto and intake restored {('never' if back is None else f'{back:5.2f} s')}")
            if not ok:
                failures.append(f"restart {i + 1}: READY {ready_s}, restored {back}")
    finally:
        quit_file.write_text("done")
        try:
            app_proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app_proc.kill()
            failures.append("app did not quit")
        robot.kill(signal.SIGTERM) if listening(port) else None
        inst.stopClient()
        ntcore.NetworkTableInstance.destroy(inst)

    if app_proc.returncode != 0:
        failures.append(f"app exited {app_proc.returncode}")
    log = (work / "chaos_app.log").read_text()
    bad = [l for l in log.splitlines() if "SCRIPT ERROR" in l or "ERROR:" in l]
    if bad:
        failures.append(f"errors in the app log: {bad[:3]}")
    report = json.loads((work / "chaos_app.json").read_text()) if (work / "chaos_app.json").exists() else {}
    if report.get("failures"):
        failures.append(f"Dev failures {report['failures']}")
    (work / "chaos_results.json").write_text(json.dumps({"seed": args.seed, "results": results, "failures": failures}, indent=2))
    worst = max((r["ready_s"] or 99 for r in results), default=0)
    print(f"{len(results)} restarts, worst READY {worst:.2f} s, {len(failures)} failure(s)")
    for f in failures:
        print("FAIL", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
