#!/usr/bin/env python3
"""TCP proxy in front of the fake robot that simulates link failures.

Listener modes (control command `mode NAME`):
- forward: accept and relay to the upstream port
- refuse: listener closed and every connection closed, so connects get a RST
  (server process down)
- drop: listener open but its accept queue is kept full and never drained, so
  new SYNs are dropped and the client's kernel retransmits them (robot booting,
  radio up but nothing answering)
- silent: TCP is accepted but nothing is ever answered (hung upgrade)
- handshake: relay until the server's HTTP upgrade response has passed, then
  freeze that connection (WebSocket open, no NT traffic)

Other commands: `freeze` / `thaw` stop and resume relaying on every existing
connection without closing it (silently dead link, no FIN); `reset` closes
every connection; `stats` reports counters; `quit` exits. Every command answers one line starting with `ok`.

Run: python3 tools/sim/net_proxy.py --listen-port P --upstream-port U --control-port C
"""

from __future__ import annotations

import argparse
import os
import selectors
import socket
import sys
import time

MODES = ("forward", "refuse", "drop", "silent", "handshake")
CHUNK = 65536


class Pair:
    def __init__(self, client: socket.socket, upstream: socket.socket, handshake_only: bool):
        self.client = client
        self.upstream = upstream
        self.frozen = False
        self.handshake_only = handshake_only
        self.seen = b""


class Proxy:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.sel = selectors.DefaultSelector()
        self.mode = "forward"
        self.listener: socket.socket | None = None
        self.fillers: list[socket.socket] = []
        self.filler_ports: set[int] = set()
        self.silent: list[socket.socket] = []
        self.pairs: dict[socket.socket, Pair] = {}
        self.accepted = 0
        self.ctl = socket.create_server(("127.0.0.1", args.control_port), reuse_port=False)
        self.ctl.setblocking(False)
        self.sel.register(self.ctl, selectors.EVENT_READ, ("ctl_accept", None))
        self.ctl_buf: dict[socket.socket, bytes] = {}
        self._open_listener()

    def _open_listener(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", self.args.listen_port))
        s.listen(1)
        s.setblocking(False)
        self.listener = s
        self.sel.register(s, selectors.EVENT_READ, ("accept", None))

    def _close_listener(self) -> None:
        if self.listener is None:
            return
        self.sel.unregister(self.listener)
        self.listener.close()
        self.listener = None
        for f in self.fillers:
            f.close()
        self.fillers.clear()
        self.filler_ports.clear()

    def _fill_queue(self) -> None:
        # One completed filler fills a backlog-1 queue; a second pending one
        # makes sure every later SYN is dropped instead of queued.
        for _ in range(2):
            f = socket.socket()
            f.setblocking(False)
            f.connect_ex(("127.0.0.1", self.args.listen_port))
            self.filler_ports.add(f.getsockname()[1])
            self.fillers.append(f)
        time.sleep(0.05)

    def set_mode(self, mode: str) -> str:
        if mode not in MODES:
            return "err unknown mode"
        prev = self.mode
        self.mode = mode
        if mode == "refuse":
            self._close_listener()
            self._reset()
        else:
            if self.listener is None:
                self._open_listener()
            if mode == "drop" and prev != "drop":
                self.sel.unregister(self.listener)
                self._fill_queue()
            elif prev == "drop" and mode != "drop":
                self.sel.register(self.listener, selectors.EVENT_READ, ("accept", None))
        return "ok mode %s" % mode

    def _on_accept(self) -> None:
        while self.listener is not None:
            try:
                c, addr = self.listener.accept()
            except (BlockingIOError, InterruptedError):
                return
            if addr[1] in self.filler_ports:
                self.filler_ports.discard(addr[1])
                c.close()
                continue
            self.accepted += 1
            c.setblocking(False)
            if self.mode == "silent":
                self.silent.append(c)
                continue
            try:
                u = socket.create_connection(("127.0.0.1", self.args.upstream_port), timeout=2.0)
            except OSError:
                c.close()
                continue
            u.setblocking(False)
            for s in (c, u):
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            p = Pair(c, u, self.mode == "handshake")
            self.pairs[c] = p
            self.pairs[u] = p
            self.sel.register(c, selectors.EVENT_READ, ("relay", p))
            self.sel.register(u, selectors.EVENT_READ, ("relay", p))

    def _drop_pair(self, p: Pair) -> None:
        self._unregister_pair(p)
        for s in (p.client, p.upstream):
            self.pairs.pop(s, None)
            s.close()

    def _unregister_pair(self, p: Pair) -> None:
        for s in (p.client, p.upstream):
            try:
                self.sel.unregister(s)
            except (KeyError, ValueError):
                pass

    def _relay(self, src: socket.socket, p: Pair) -> None:
        if p.frozen:
            self._unregister_pair(p)
            return
        dst = p.upstream if src is p.client else p.client
        try:
            data = src.recv(CHUNK)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            self._drop_pair(p)
            return
        if p.handshake_only and src is p.upstream:
            p.seen += data
            end = p.seen.find(b"\r\n\r\n")
            if end >= 0:
                cut = len(data) - (len(p.seen) - (end + 4))
                data = data[:cut]
                p.frozen = True
                self._unregister_pair(p)
        try:
            dst.setblocking(True)
            dst.sendall(data)
            dst.setblocking(False)
        except OSError:
            self._drop_pair(p)

    def _reset(self) -> int:
        pairs = {id(p): p for p in self.pairs.values()}
        for p in pairs.values():
            self._drop_pair(p)
        for c in self.silent:
            c.close()
        self.silent.clear()
        return len(pairs)

    def _set_frozen(self, frozen: bool) -> None:
        seen = set()
        for p in self.pairs.values():
            if id(p) in seen:
                continue
            seen.add(id(p))
            p.frozen = frozen
            self._unregister_pair(p)
            if not frozen:
                p.handshake_only = False
                for s in (p.client, p.upstream):
                    self.sel.register(s, selectors.EVENT_READ, ("relay", p))

    def _command(self, line: str) -> str:
        parts = line.split()
        if not parts:
            return "err empty"
        cmd = parts[0]
        if cmd == "mode" and len(parts) == 2:
            return self.set_mode(parts[1])
        if cmd == "freeze":
            self._set_frozen(True)
            return "ok frozen %d" % (len(self.pairs) // 2)
        if cmd == "thaw":
            self._set_frozen(False)
            return "ok thawed %d" % (len(self.pairs) // 2)
        if cmd == "reset":
            return "ok reset %d" % self._reset()
        if cmd == "stats":
            return "ok mode=%s accepted=%d pairs=%d silent=%d" % (self.mode, self.accepted, len(self.pairs) // 2, len(self.silent))
        if cmd == "quit":
            raise SystemExit(0)
        return "err unknown command"

    def _on_ctl(self, s: socket.socket) -> None:
        try:
            data = s.recv(4096)
        except OSError:
            data = b""
        if not data:
            self.sel.unregister(s)
            self.ctl_buf.pop(s, None)
            s.close()
            return
        buf = self.ctl_buf.get(s, b"") + data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            reply = self._command(line.decode(errors="replace").strip())
            s.setblocking(True)
            s.sendall((reply + "\n").encode())
            s.setblocking(False)
        self.ctl_buf[s] = buf

    def run(self) -> None:
        while True:
            for key, _ in self.sel.select(timeout=0.5):
                kind, p = key.data
                if kind == "accept":
                    self._on_accept()
                elif kind == "relay":
                    if key.fileobj in self.pairs:
                        self._relay(key.fileobj, p)
                elif kind == "ctl_accept":
                    c, _ = self.ctl.accept()
                    c.setblocking(False)
                    self.sel.register(c, selectors.EVENT_READ, ("ctl", None))
                elif kind == "ctl":
                    self._on_ctl(key.fileobj)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-port", type=int, required=True)
    ap.add_argument("--upstream-port", type=int, required=True)
    ap.add_argument("--control-port", type=int, required=True)
    ap.add_argument("--pid-file", default="")
    ap.add_argument("--tag", default="", help="ignored; lets scripts find this process")
    args = ap.parse_args()
    if args.pid_file:
        with open(args.pid_file, "w") as f:
            f.write(str(os.getpid()))
    proxy = Proxy(args)
    print("net_proxy listening on %d -> %d, control %d" % (args.listen_port, args.upstream_port, args.control_port), flush=True)
    try:
        proxy.run()
    except (KeyboardInterrupt, SystemExit):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
