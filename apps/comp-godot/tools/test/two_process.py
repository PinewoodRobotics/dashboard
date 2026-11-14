# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["pyntcore==2026.2.2"]
# ///
"""Two-process fallback: --screen=hud and --screen=touch as separate processes
against one fake robot. Each has its own stored auto and intake choice. The
HUD process runs alone first and must publish nothing (the robot keeps its
defaults and logs no request); then the touch process starts and its choice,
and only its choice, reaches the robot while both stay connected.

Usage: uv run tools/test/two_process.py --app APP --godot GODOT --work DIR
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import ntcore

HUD_CHOICE = ("Stay And Shoot", 0.11)
TOUCH_CHOICE = ("Ball Shooter Right", 0.42)
AUTO_STATE = "/Shared/PathPlanner/SelectedPath/State"
INTAKE_STATE = "/Shared/Intake/Speed/State"
REQUEST_LOG = "/fake/request_log"
CONNECTIONS = "/fake/connections"


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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--godot", default="godot")
    ap.add_argument("--work", required=True)
    args = ap.parse_args()
    app, work = Path(args.app), Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    port = free_port()
    tag = f"comp-godot-two-{os.getpid()}"
    robot_log = open(work / "two_robot.log", "w")
    robot = subprocess.Popen(["uv", "run", "--quiet", "--script", str(app / "tools/sim/fake_robot.py"), "--port", str(port),
                              "--tag", tag, "--alliance", "blue", "--pose", "3,4,0"], stdout=robot_log, stderr=subprocess.STDOUT)
    deadline = time.time() + 20
    while not listening(port) and time.time() < deadline:
        time.sleep(0.05)
    env = dict(os.environ, PWRUP_SHARED_SETTINGS_PATH=str(work / "two_connection.json"))
    failures: list[str] = []

    def check(cond: bool, msg: str) -> None:
        print(("ok   " if cond else "FAIL ") + msg)
        if not cond:
            failures.append(msg)

    def launch(screen: str, choice: tuple[str, float], quit_file: Path) -> subprocess.Popen:
        settings = work / f"two_{screen}_settings.json"
        settings.write_text(json.dumps({"controls": {"selected_auto": choice[0], "intake_speed": choice[1]}}))
        quit_file.unlink(missing_ok=True)
        log = open(work / f"two_{screen}.log", "w")
        return subprocess.Popen(
            [args.godot, "--path", str(app), "--", f"--screen={screen}", "--live", "--nt-host=127.0.0.1", f"--nt-port={port}",
             f"--settings={settings}", f"--quit-file={quit_file}", "--frames=10", "--run-s=120",
             f"--report={work / f'two_{screen}.json'}"],
            stdout=log, stderr=subprocess.STDOUT, env=env)

    inst = ntcore.NetworkTableInstance.create()
    inst.startClient4("two-process-observer")
    inst.setServer("127.0.0.1", port)
    auto = inst.getStringTopic(AUTO_STATE).subscribe("")
    intake = inst.getDoubleTopic(INTAKE_STATE).subscribe(-2.0)
    log_sub = inst.getStringArrayTopic(REQUEST_LOG).subscribe([])
    conns = inst.getIntegerTopic(CONNECTIONS).subscribe(0)

    def wait(cond, timeout: float) -> float | None:
        t0 = time.time()
        while time.time() - t0 < timeout:
            if cond():
                return time.time() - t0
            time.sleep(0.02)
        return None

    hud_quit, touch_quit = work / "two_hud.quit", work / "two_touch.quit"
    hud = touch = None
    try:
        wait(lambda: inst.isConnected() and auto.get() != "", 10)
        hud = launch("hud", HUD_CHOICE, hud_quit)
        check(wait(lambda: conns.get() >= 2, 15) is not None, f"HUD process connected ({conns.get()} NT clients)")
        time.sleep(4.0)
        check(auto.get() == "NONE" and abs(intake.get() - 0.5) < 1e-9 and list(log_sub.get()) == [],
              f"HUD process alone publishes nothing: State {auto.get()!r} / {intake.get()}, request log {list(log_sub.get())}")
        touch = launch("touch", TOUCH_CHOICE, touch_quit)
        el = wait(lambda: auto.get() == TOUCH_CHOICE[0] and abs(intake.get() - TOUCH_CHOICE[1]) < 1e-9, 20)
        check(el is not None, f"touch process choice reaches the robot ({auto.get()!r} / {intake.get()}"
              + (f", {el:.2f} s after launch)" if el is not None else ")"))
        check(wait(lambda: conns.get() >= 3, 5) is not None, f"both dashboards and the observer connected ({conns.get()})")
        time.sleep(3.0)
        req = list(log_sub.get())
        check(req and all(v == TOUCH_CHOICE[0] for v in req), f"every auto request came from the touch process: {req}")
        check(auto.get() == TOUCH_CHOICE[0] and abs(intake.get() - TOUCH_CHOICE[1]) < 1e-9,
              "State still holds the touch choice with both processes running")
    finally:
        for f in (hud_quit, touch_quit):
            f.write_text("done")
        for name, p in (("hud", hud), ("touch", touch)):
            if p is None:
                continue
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                p.kill()
                failures.append(f"{name} process did not quit")
        inst.stopClient()
        ntcore.NetworkTableInstance.destroy(inst)
        robot.send_signal(signal.SIGTERM)
        try:
            robot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            robot.kill()
        subprocess.run(["pkill", "-f", "--", f"--tag {tag}"], check=False)

    for name, p in (("hud", hud), ("touch", touch)):
        if p is None:
            continue
        r = json.loads((work / f"two_{name}.json").read_text())
        c = r["controls"]
        log = (work / f"two_{name}.log").read_text()
        check(p.returncode == 0 and not r["failures"], f"{name} process exited 0 with no Dev failures {r['failures']}")
        check("SCRIPT ERROR" not in log and "ERROR:" not in log, f"{name} process log has no errors")
        check(list(r["windows"].keys()) == [name], f"{name} process has one window ({list(r['windows'].keys())})")
        if name == "hud":
            check(c["read_only"] and c["publishers"] == 0 and c["auto"]["publishes"] == 0 and c["intake"]["publishes"] == 0,
                  f"HUD controls are read-only with no publishers (publishers {c['publishers']}, "
                  f"auto {c['auto']['publishes']}, intake {c['intake']['publishes']})")
        else:
            check(not c["read_only"] and c["publishers"] >= 2 and c["auto"]["publishes"] >= 1,
                  f"touch controls publish (publishers {c['publishers']}, auto {c['auto']['publishes']}, intake {c['intake']['publishes']})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
