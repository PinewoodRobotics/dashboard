# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["pyntcore==2026.2.2"]
# ///
"""Fake robot: a real ntcore NT4 server that plays the parts of the FIR robot
the dashboard talks to.

- /matchhud/state/* with the robot's names and types, written and flushed every
  20 ms. The flush stands in for the 2027 ntcore server on the robot, which
  honors a 20 ms subscriber period; the 2026 pyntcore server batches about
  every 100 ms without it (--no-flush)
- Shared request/state pairs (auto selection, intake speed) echoed like
  SharedStringTopic/SharedDoubleTopic: State follows Request, and falls back
  to the default as soon as the writer disconnects (requests are not retained)
- /Tuning/Turret/AimTrimDeg echoed to /AdvantageKit/NetworkInputs/...
- /fake/types/* with one topic per NT type, for decode tests
- /fake/uptime_s and /fake/request_log (every Request value received, in order)
- optional /fake/load/* doubles so the server holds --total-topics topics,
  changing at --load-hz (runtime override: /fake/control/load_hz)
- robot pose and the AdvantageKit joint topics (wrist, turret; climber only with
  --climber since the FIR robot has no climber output). Default: parked at 5, 5
  with a spinning heading; --pose X,Y,H parks it; --motion drives a loop on the
  blue half with the wrist and turret moving. Runtime overrides:
  /fake/control/pose (double[3]), /fake/control/wrist, /fake/control/turret,
  /fake/control/climber (doubles, NaN = no override), /fake/control/alliance
  ("red", "blue", or "" for the --alliance default)

Run: uv run tools/sim/fake_robot.py --port 5810
"""

from __future__ import annotations

import argparse
import math
import os
import signal
import sys
import tempfile
import time

import ntcore

MATCH_STATE = {
    "seq": "int",
    "robot_time_us": "int",
    "connected": "boolean",
    "is_red_alliance": "boolean",
    "enabled": "boolean",
    "autonomous": "boolean",
    "game_specific_message": "string",
    "match_phase": "int",
    "hub_status": "int",
    "header_color": "int",
    "total_time_remaining_s": "double",
    "period_time_remaining_s": "double",
    "shift_time_remaining_s": "double",
    "shift_time_with_buffer_s": "double",
    "buffer_remaining_s": "double",
    "is_shooting": "boolean",
    "show_shift_indicator": "boolean",
    "show_buffer": "boolean",
    "robot_pose_x_m": "double",
    "robot_pose_y_m": "double",
    "robot_heading_rad": "double",
    "robot_pose_valid": "boolean",
    "auto_align_active": "boolean",
    "auto_align_distance_m": "double",
    "auto_align_ready": "boolean",
    "driver_override": "boolean",
    "aim_mode": "int",
}

STATIC_MATCH_VALUES = {
    "connected": True,
    "is_red_alliance": False,
    "enabled": False,
    "autonomous": False,
    "game_specific_message": "B",
    "match_phase": 0,
    "hub_status": 0,
    "header_color": 0,
    "total_time_remaining_s": 160.0,
    "period_time_remaining_s": -1.0,
    "shift_time_remaining_s": 0.0,
    "shift_time_with_buffer_s": 0.0,
    "buffer_remaining_s": 0.0,
    "is_shooting": False,
    "show_shift_indicator": False,
    "show_buffer": False,
    "robot_pose_x_m": 5.0,
    "robot_pose_y_m": 5.0,
    "robot_heading_rad": 0.0,
    "robot_pose_valid": True,
    "auto_align_active": False,
    "auto_align_distance_m": 0.0,
    "auto_align_ready": False,
    "driver_override": False,
    "aim_mode": 1,
}

TYPE_VALUES = {
    "bool": ("boolean", True),
    "int": ("int", 1234567890123),
    "int_min": ("int", -(2**63)),
    "int_max": ("int", 2**63 - 1),
    "double": ("double", 3.141592653589793),
    "float": ("float", 1.5),
    "string": ("string", "Höhe 4765"),
    "raw": ("raw", bytes([0, 1, 2, 254, 255])),
    "bool_array": ("boolean[]", [True, False, True]),
    "double_array": ("double[]", [1.5, -2.25, 1e300]),
    "int_array": ("int[]", [1, -2, 2**40]),
    "float_array": ("float[]", [0.5, -0.25]),
    "string_array": ("string[]", ["a", "", "Move Forward And Shoot Left"]),
}

VALID_AUTOS = [
    "Ball Shooter Left",
    "Ball Shooter Right",
    "Climber Right Left",
    "Climber Right Middle",
    "Climber Right Right",
    "Move Forward And Shoot Center",
    "Move Forward And Shoot Left",
    "Move Forward And Shoot Right",
    "Stay And Shoot",
]

INTAKE_DEFAULT_SPEED = 0.5

WRIST_TOPIC = "/AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition"
TURRET_TOPIC = "/AdvantageKit/RealOutputs/Turret/PositionRot"
CLIMBER_TOPIC = "/AdvantageKit/RealOutputs/Climber/CurrentHeightMeters"


def motion_state(t: float) -> tuple[float, float, float, float, float]:
    """Pose (x, y, heading) on a loop over the blue half, wrist and turret rotations."""
    a = t * 0.4
    x = 4.0 + 2.0 * math.cos(a)
    y = 4.03 + 2.5 * math.sin(a)
    heading = math.atan2(2.5 * math.cos(a), -2.0 * math.sin(a))
    wrist = 0.169 + 0.169 * math.sin(t * 1.3)
    turret = (t * 0.1) % 1.0 - 0.5
    return x, y, heading, wrist, turret


def publisher(inst: ntcore.NetworkTableInstance, name: str, type_str: str):
    if type_str == "boolean":
        return inst.getBooleanTopic(name).publish()
    if type_str == "int":
        return inst.getIntegerTopic(name).publish()
    if type_str == "double":
        return inst.getDoubleTopic(name).publish()
    if type_str == "float":
        return inst.getFloatTopic(name).publish()
    if type_str == "string":
        return inst.getStringTopic(name).publish()
    if type_str == "raw":
        return inst.getRawTopic(name).publish("raw")
    if type_str == "boolean[]":
        return inst.getBooleanArrayTopic(name).publish()
    if type_str == "double[]":
        return inst.getDoubleArrayTopic(name).publish()
    if type_str == "int[]":
        return inst.getIntegerArrayTopic(name).publish()
    if type_str == "float[]":
        return inst.getFloatArrayTopic(name).publish()
    if type_str == "string[]":
        return inst.getStringArrayTopic(name).publish()
    raise ValueError(type_str)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5810)
    ap.add_argument("--port3", type=int, default=0, help="NT3 port (0 picks any free port)")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--pid-file", default="")
    ap.add_argument("--persist-dir", default="", help="where ntcore keeps networktables.json (default: a new temp dir)")
    ap.add_argument("--total-topics", type=int, default=0, help="pad with /fake/load/* doubles up to this many topics")
    ap.add_argument("--hz", type=float, default=50.0)
    ap.add_argument(
        "--load-hz",
        type=float,
        default=10.0,
        help="update rate of the /fake/load/* topics; /fake/control/load_hz overrides it at runtime",
    )
    ap.add_argument("--tag", default="", help="ignored; lets scripts find this process")
    ap.add_argument("--pose", default="", help="park the robot at X,Y,HEADING (m, m, rad)")
    ap.add_argument("--motion", action="store_true", help="drive a loop with moving wrist and turret")
    ap.add_argument("--alliance", choices=["red", "blue"], default="blue")
    ap.add_argument("--wrist", type=float, default=0.0, help="wrist rotations when not in --motion")
    ap.add_argument("--turret", type=float, default=0.0, help="turret rotations when not in --motion")
    ap.add_argument("--climber", type=float, default=None, help="publish the climber topic with this height (m)")
    ap.add_argument(
        "--no-flush",
        action="store_true",
        help="do not call flush() each loop; pyntcore 2026 then sends about every 100 ms",
    )
    args = ap.parse_args()

    if args.pid_file:
        with open(args.pid_file, "w") as f:
            f.write(str(os.getpid()))

    if args.persist_dir:
        os.makedirs(args.persist_dir, exist_ok=True)
        persist_dir = args.persist_dir
    else:
        persist_dir = tempfile.mkdtemp(prefix="fake-robot-nt-")
    inst = ntcore.NetworkTableInstance.create()
    inst.startServer(os.path.join(persist_dir, "networktables.json"), args.listen, args.port3, args.port)

    match_pubs = {k: publisher(inst, "/matchhud/state/" + k, t) for k, t in MATCH_STATE.items()}
    for k, v in STATIC_MATCH_VALUES.items():
        match_pubs[k].set(v)
    match_pubs["is_red_alliance"].set(args.alliance == "red")

    parked = None
    if args.pose:
        parked = tuple(float(v) for v in args.pose.split(","))
        if len(parked) != 3:
            ap.error("--pose needs X,Y,HEADING")
    wrist_pub = inst.getDoubleTopic(WRIST_TOPIC).publish()
    turret_pub = inst.getDoubleTopic(TURRET_TOPIC).publish()
    climber_pub = inst.getDoubleTopic(CLIMBER_TOPIC).publish() if args.climber is not None else None
    pose_ctl = inst.getDoubleArrayTopic("/fake/control/pose").subscribe([])
    wrist_ctl = inst.getDoubleTopic("/fake/control/wrist").subscribe(math.nan)
    turret_ctl = inst.getDoubleTopic("/fake/control/turret").subscribe(math.nan)
    climber_ctl = inst.getDoubleTopic("/fake/control/climber").subscribe(math.nan)
    alliance_ctl = inst.getStringTopic("/fake/control/alliance").subscribe("")

    type_pubs = {}
    for k, (t, v) in TYPE_VALUES.items():
        p = publisher(inst, "/fake/types/" + k, t)
        p.set(v)
        type_pubs[k] = p

    uptime_pub = inst.getDoubleTopic("/fake/uptime_s").publish()
    log_pub = inst.getStringArrayTopic("/fake/request_log").publish()

    auto_req = inst.getStringTopic("/Shared/PathPlanner/SelectedPath/Request").subscribe(
        "NONE", ntcore.PubSubOptions(sendAll=True, keepDuplicates=True, pollStorage=64)
    )
    auto_state = inst.getStringTopic("/Shared/PathPlanner/SelectedPath/State").publish()
    auto_state.set("NONE")
    intake_req = inst.getDoubleTopic("/Shared/Intake/Speed/Request").subscribe(-1.0)
    intake_state = inst.getDoubleTopic("/Shared/Intake/Speed/State").publish()
    intake_state.set(INTAKE_DEFAULT_SPEED)
    trim_sub = inst.getDoubleTopic("/Tuning/Turret/AimTrimDeg").subscribe(0.0)
    trim_readback = inst.getDoubleTopic("/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg").publish()
    trim_readback.set(0.0)
    pp_current = inst.getStringTopic("/AdvantageKit/RealOutputs/PathPlanner/CurrentSelectedAuto").publish()
    pp_valid = inst.getBooleanTopic("/AdvantageKit/RealOutputs/PathPlanner/SelectedAutoValid").publish()
    pp_names = inst.getStringArrayTopic("/AdvantageKit/RealOutputs/PathPlanner/ValidNames/Autos").publish()
    pp_names.set(VALID_AUTOS)

    load_hz_sub = inst.getDoubleTopic("/fake/control/load_hz").subscribe(args.load_hz)

    base_count = len(match_pubs) + len(type_pubs) + 8
    load_pubs = []
    for i in range(max(0, args.total_topics - base_count)):
        load_pubs.append(inst.getDoubleTopic(f"/fake/load/{i:04d}").publish())

    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"fake_robot listening on {args.listen}:{args.port} pid={os.getpid()} topics={base_count + len(load_pubs)}", flush=True)

    period = 1.0 / args.hz
    start = time.monotonic()
    next_t = start
    seq = 0
    request_log: list[str] = []
    while running:
        now = time.monotonic()
        seq += 1
        uptime = now - start
        match_pubs["seq"].set(seq)
        match_pubs["robot_time_us"].set(int(uptime * 1e6))
        if args.motion:
            x, y, heading, wrist, turret = motion_state(uptime)
        else:
            x, y, heading = parked if parked else (5.0, 5.0, math.fmod(uptime * 0.5, 2 * math.pi) - math.pi)
            wrist, turret = args.wrist, args.turret
        pose_override = pose_ctl.get()
        if len(pose_override) == 3:
            x, y, heading = pose_override
        w = wrist_ctl.get()
        t = turret_ctl.get()
        c = climber_ctl.get()
        wrist = wrist if math.isnan(w) else w
        turret = turret if math.isnan(t) else t
        match_pubs["robot_pose_x_m"].set(x)
        match_pubs["robot_pose_y_m"].set(y)
        match_pubs["robot_heading_rad"].set(heading)
        wrist_pub.set(wrist)
        turret_pub.set(turret)
        if climber_pub is not None:
            climber_pub.set(args.climber if math.isnan(c) else c)
        alliance = alliance_ctl.get() or args.alliance
        match_pubs["is_red_alliance"].set(alliance == "red")
        uptime_pub.set(uptime)

        for v in auto_req.readQueue():
            request_log.append(v.value)
        if len(request_log) > 64:
            request_log = request_log[-64:]
        log_pub.set(request_log)
        auto_name = auto_req.get()
        auto_state.set(auto_name)
        pp_current.set(auto_name)
        pp_valid.set(auto_name in VALID_AUTOS)

        requested = intake_req.get()
        intake_state.set(requested if 0.0 <= requested <= 1.0 else INTAKE_DEFAULT_SPEED)
        trim_readback.set(trim_sub.get())

        load_hz = load_hz_sub.get()
        load_every = max(1, round(args.hz / load_hz)) if load_hz > 0 else 0
        if load_every and seq % load_every == 0:
            for i, p in enumerate(load_pubs):
                p.set(seq + i * 0.001)

        if not args.no_flush:
            inst.flush()

        next_t += period
        delay = next_t - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_t = time.monotonic()

    inst.stopServer()
    if args.pid_file:
        try:
            os.remove(args.pid_file)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
