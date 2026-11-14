class_name FakeRobotProc
extends RefCounted

## Handle on the fake robot started by tools/test/run_integration.sh, which
## passes PWRUP_FAKE_ROBOT_PORT, _PIDFILE and _CMD (JSON argv used to restart it).

var port := 0
var pid_file := ""
var cmd: Array = []


static func from_env() -> FakeRobotProc:
	var p := OS.get_environment("PWRUP_FAKE_ROBOT_PORT")
	if p == "":
		return null
	var r := FakeRobotProc.new()
	r.port = int(p)
	r.pid_file = OS.get_environment("PWRUP_FAKE_ROBOT_PIDFILE")
	var parsed: Variant = JSON.parse_string(OS.get_environment("PWRUP_FAKE_ROBOT_CMD"))
	r.cmd = parsed if typeof(parsed) == TYPE_ARRAY else []
	return r


func pid() -> int:
	if not FileAccess.file_exists(pid_file):
		return -1
	return int(FileAccess.get_file_as_string(pid_file).strip_edges())


func is_listening() -> bool:
	return OS.execute("nc", ["-z", "-G", "1", "127.0.0.1", str(port)]) == 0


func kill() -> bool:
	var p := pid()
	if p <= 0:
		return false
	return OS.kill(p) == OK


func signal_process(sig: String) -> bool:
	var p := pid()
	return p > 0 and OS.execute("kill", ["-" + sig, str(p)]) == 0


func restart() -> int:
	if cmd.is_empty():
		return -1
	var args: PackedStringArray = []
	for a: Variant in cmd.slice(1):
		args.append(str(a))
	return OS.create_process(str(cmd[0]), args)
