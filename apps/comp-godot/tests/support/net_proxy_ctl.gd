class_name NetProxyCtl
extends RefCounted

## Control client for tools/sim/net_proxy.py, started by
## tools/test/run_integration.sh in front of the fake robot
## (PWRUP_NET_PROXY_PORT, PWRUP_NET_PROXY_CONTROL).

var port := 0
var control_port := 0
var _peer: StreamPeerTCP


static func from_env() -> NetProxyCtl:
	var p := OS.get_environment("PWRUP_NET_PROXY_PORT")
	var c := OS.get_environment("PWRUP_NET_PROXY_CONTROL")
	if p == "" or c == "":
		return null
	var ctl := NetProxyCtl.new()
	ctl.port = int(p)
	ctl.control_port = int(c)
	return ctl


## Sends one command and returns the proxy's reply line ("" on failure).
func send(cmd: String, timeout_s: float = 2.0) -> String:
	if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer = StreamPeerTCP.new()
		if _peer.connect_to_host("127.0.0.1", control_port) != OK:
			return ""
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		_peer.poll()
		OS.delay_usec(500)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return ""
	_peer.put_data((cmd + "\n").to_utf8_buffer())
	var line := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var n := _peer.get_available_bytes()
		if n > 0:
			var r := _peer.get_data(n)
			line.append_array(r[1])
			if line.has(10):
				return line.get_string_from_utf8().strip_edges()
		else:
			OS.delay_usec(500)
	return ""


func mode(name: String) -> bool:
	return send("mode " + name).begins_with("ok")


func close() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
