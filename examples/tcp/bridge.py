#!/usr/bin/env python3
"""Bounded TCP socket bridge for examples/tcp/session.goose.

Architecture (honest adapter evidence):
  - This process owns TCP: connect, short recv/send, timeouts, EOF/RESET/TIMEOUT.
  - Goose owns examples/stream feed/frame/commit_rx and enqueue/drain/commit_tx
    plus honkmqtt codecs. Python never frames MQTT and never acks unsent bytes.

SEND replies with the actual ``socket.send`` byte count (one call). Goose must
wait and ``commit_tx`` exactly that count. RECV returns at most the requested
cap (Goose should request ≤ free RX window).
"""

from __future__ import annotations

import argparse
import errno
import os
import select
import socket
import subprocess
import sys
import threading
import time
from typing import List, Optional, Tuple

IPC_MAX = 512
CONNECT_TIMEOUT_S = 2.0
IO_TIMEOUT_S = 2.0
CASE_TIMEOUT_S = 15.0

MSG_SEND = 1
MSG_RECV = 2
MSG_EVENT = 3
MSG_DONE = 4
MSG_FATAL = 5
MSG_RECONNECT = 6
MSG_DATA = 10
MSG_ERR = 11


class BridgeError(RuntimeError):
    pass


def remaining_s(deadline: float) -> float:
    return max(0.0, deadline - time.monotonic())


def classify_socket_error(exc: BaseException) -> str:
    if isinstance(exc, socket.timeout):
        return "TIMEOUT"
    if isinstance(exc, ConnectionResetError):
        return "RESET"
    if isinstance(exc, BrokenPipeError):
        return "RESET"
    if isinstance(exc, OSError):
        if exc.errno in (errno.ECONNRESET, getattr(errno, "WSAECONNRESET", -1)):
            return "RESET"
        if exc.errno in (errno.EPIPE, getattr(errno, "WSAECONNABORTED", -1)):
            return "RESET"
        if exc.errno in (errno.ETIMEDOUT, getattr(errno, "WSAETIMEDOUT", -1)):
            return "TIMEOUT"
        return f"ERROR:{exc.errno}"
    return f"ERROR:{type(exc).__name__}"


def connect_tcp(host: str, port: int, deadline: float) -> socket.socket:
    timeout = min(CONNECT_TIMEOUT_S, remaining_s(deadline) or CONNECT_TIMEOUT_S)
    if timeout <= 0:
        raise BridgeError("CASE_TIMEOUT")
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def write_msg(pipe, kind: int, payload: bytes = b"") -> None:
    if len(payload) > IPC_MAX:
        raise BridgeError(f"ipc payload {len(payload)} > {IPC_MAX}")
    pipe.write(bytes([kind, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF]))
    if payload:
        pipe.write(payload)
    pipe.flush()


def read_exact(pipe, n: int, deadline: float) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        left = remaining_s(deadline)
        if left <= 0:
            raise BridgeError("CASE_TIMEOUT")
        # Avoid blocking past the case deadline on the Goose pipe.
        readable, _, _ = select.select([pipe], [], [], left)
        if not readable:
            raise BridgeError("CASE_TIMEOUT")
        chunk = pipe.read(n - len(buf))
        if not chunk:
            raise BridgeError(f"goose pipe EOF after {len(buf)}/{n} bytes")
        buf.extend(chunk)
    return bytes(buf)


def read_msg(pipe, deadline: float) -> Tuple[int, bytes]:
    hdr = read_exact(pipe, 3, deadline)
    kind, length = hdr[0], (hdr[1] << 8) | hdr[2]
    if length > IPC_MAX:
        raise BridgeError(f"ipc payload {length} > {IPC_MAX}")
    payload = read_exact(pipe, length, deadline) if length else b""
    return kind, payload


def set_sock_timeout(sock: socket.socket, deadline: float) -> None:
    left = remaining_s(deadline)
    if left <= 0:
        raise BridgeError("CASE_TIMEOUT")
    sock.settimeout(min(IO_TIMEOUT_S, left))


def run_bridge(
    goose_cmd: List[str],
    host: str,
    port: int,
    case_timeout_s: float = CASE_TIMEOUT_S,
) -> Tuple[int, List[str], Optional[str]]:
    """Run Goose session with TCP bridge. Returns (exit_code, events, peer_close)."""
    events: List[str] = []
    peer_close: Optional[str] = None
    deadline = time.monotonic() + case_timeout_s
    timed_out = threading.Event()

    sock = connect_tcp(host, port, deadline)
    proc = subprocess.Popen(
        goose_cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    assert proc.stdin is not None and proc.stdout is not None

    def watchdog() -> None:
        delay = remaining_s(deadline)
        if delay > 0:
            timed_out.wait(timeout=delay)
        if proc.poll() is None:
            timed_out.set()
            try:
                proc.kill()
            except OSError:
                pass
            # Unblock any stuck pipe read in the parent.
            try:
                if proc.stdout:
                    proc.stdout.close()
            except OSError:
                pass
            try:
                if proc.stdin:
                    proc.stdin.close()
            except OSError:
                pass

    watcher = threading.Thread(target=watchdog, name="bridge-watchdog", daemon=True)
    watcher.start()

    try:
        while True:
            if timed_out.is_set() or remaining_s(deadline) <= 0:
                raise BridgeError("CASE_TIMEOUT")
            kind, payload = read_msg(proc.stdout, deadline)
            if kind == MSG_SEND:
                if not payload:
                    write_msg(proc.stdin, MSG_DATA, b"\x00\x00")
                    continue
                try:
                    set_sock_timeout(sock, deadline)
                    # One send() — report actual short-write count; Goose commits that.
                    sent = sock.send(payload)
                    if sent < 0:
                        raise OSError("send returned negative")
                    if sent == 0:
                        raise BrokenPipeError("send returned 0")
                    write_msg(
                        proc.stdin,
                        MSG_DATA,
                        bytes([(sent >> 8) & 0xFF, sent & 0xFF]),
                    )
                except BridgeError:
                    raise
                except BaseException as exc:
                    reason = classify_socket_error(exc)
                    peer_close = reason
                    write_msg(proc.stdin, MSG_ERR, reason.encode("utf-8"))
            elif kind == MSG_RECV:
                if len(payload) != 2:
                    raise BridgeError("RECV max_n must be 2 bytes")
                max_n = (payload[0] << 8) | payload[1]
                if max_n <= 0 or max_n > IPC_MAX:
                    raise BridgeError(f"bad max_n {max_n}")
                try:
                    set_sock_timeout(sock, deadline)
                    data = sock.recv(max_n)
                    if data == b"":
                        peer_close = peer_close or "EOF"
                        write_msg(proc.stdin, MSG_DATA, b"")
                    else:
                        write_msg(proc.stdin, MSG_DATA, data)
                except BridgeError:
                    raise
                except BaseException as exc:
                    reason = classify_socket_error(exc)
                    peer_close = reason
                    write_msg(proc.stdin, MSG_ERR, reason.encode("utf-8"))
            elif kind == MSG_EVENT:
                events.append(payload.decode("utf-8", errors="replace"))
            elif kind == MSG_DONE:
                code = payload[0] if payload else 0
                timed_out.set()  # stop watchdog wait
                return code, events, peer_close
            elif kind == MSG_FATAL:
                msg = payload.decode("utf-8", errors="replace")
                raise BridgeError(f"goose fatal: {msg}")
            elif kind == MSG_RECONNECT:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    sock.close()
                except OSError:
                    pass
                sock = connect_tcp(host, port, deadline)
                write_msg(proc.stdin, MSG_DATA, b"")
            else:
                raise BridgeError(f"unknown goose msg {kind}")
    finally:
        timed_out.set()
        try:
            sock.close()
        except OSError:
            pass
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        stderr = ""
        if proc.stderr:
            try:
                stderr = proc.stderr.read().decode("utf-8", errors="replace")
            except OSError:
                stderr = ""
        if stderr.strip():
            sys.stderr.write(stderr)
            if not stderr.endswith("\n"):
                sys.stderr.write("\n")
        try:
            proc.wait(timeout=2)
        except Exception:
            pass


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--goose", default=os.environ.get("GOOSE", "goose"))
    p.add_argument("--session", required=True, help="path to session.goose")
    p.add_argument("--scenario", default="positive")
    p.add_argument("--client-id", default="honk-m3")
    p.add_argument("--case-timeout", type=float, default=CASE_TIMEOUT_S)
    args = p.parse_args()

    cmd = [
        args.goose,
        args.session,
        "--",
        args.scenario,
        args.client_id,
    ]
    try:
        code, events, peer_close = run_bridge(
            cmd, args.host, args.port, case_timeout_s=args.case_timeout
        )
    except BridgeError as exc:
        print(f"BRIDGE_FAIL {exc}", file=sys.stderr)
        return 2

    for ev in events:
        print(f"EVENT {ev}")
    if peer_close:
        print(f"PEER_CLOSE {peer_close}")
    print(
        "BRIDGE_QUOTAS "
        f"ipc_max={IPC_MAX} connect_timeout_s={CONNECT_TIMEOUT_S} "
        f"io_timeout_s={IO_TIMEOUT_S} case_timeout_s={args.case_timeout}"
    )
    print(f"EXIT {code}")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
