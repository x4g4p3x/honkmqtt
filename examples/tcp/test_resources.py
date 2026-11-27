#!/usr/bin/env python3
"""Controlled loopback checks for TCP bridge bounds, deadlines, and cleanup."""

from __future__ import annotations

import io
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest.mock import Mock, patch

import bridge as bridge_module
from bridge import BridgeError, IPC_MAX, MSG_DATA, read_exact, read_msg, run_bridge, write_msg


def python_child(source: str, *args: str) -> list[str]:
    return [sys.executable, "-u", "-c", source, *args]


def test_ipc_limit() -> None:
    read_fd, write_fd = os.pipe()
    with os.fdopen(read_fd, "rb", buffering=0) as pipe, os.fdopen(
        write_fd, "wb", buffering=0
    ) as writer:
        writer.write(bytes([MSG_DATA, (IPC_MAX + 1) >> 8, (IPC_MAX + 1) & 0xFF]))
        try:
            read_msg(pipe, time.monotonic() + 1)
        except BridgeError as exc:
            assert "ipc payload" in str(exc)
        else:
            raise AssertionError("oversized IPC length was admitted")
    try:
        write_msg(io.BytesIO(), MSG_DATA, bytes(IPC_MAX + 1))
    except BridgeError as exc:
        assert "ipc payload" in str(exc)
    else:
        raise AssertionError("oversized IPC write was admitted")
    print(f"ok: IPC rejects payloads above {IPC_MAX} bytes")


def expect_pipe_error(pipe: object, *, remaining: list[float], select_side_effect=None) -> str:
    with patch.object(bridge_module, "remaining_s", side_effect=remaining), patch.object(
        bridge_module.select, "select", side_effect=select_side_effect
    ):
        try:
            read_exact(pipe, 1, 123.0)
        except BridgeError as exc:
            return str(exc)
    raise AssertionError("read_exact unexpectedly succeeded")


def test_read_exact_deadline_races() -> None:
    # The watchdog may close the pipe descriptor before select gets to inspect
    # it. Once the deadline has expired, that select error must be a timeout.
    closed_fd = expect_pipe_error(
        object(), remaining=[1.0, 0.0], select_side_effect=ValueError("closed file")
    )
    assert closed_fd == "CASE_TIMEOUT", closed_fd

    # A killed child may signal EOF before the watchdog closes the pipe object.
    # Expired EOF is likewise a timeout, while earlier EOF keeps its own error.
    eof_pipe = Mock()
    eof_pipe.read.return_value = b""
    expired_eof = expect_pipe_error(
        eof_pipe, remaining=[1.0, 0.0], select_side_effect=([[eof_pipe], [], []],)
    )
    assert expired_eof == "CASE_TIMEOUT", expired_eof

    early_eof = expect_pipe_error(
        eof_pipe, remaining=[1.0, 1.0], select_side_effect=([[eof_pipe], [], []],)
    )
    assert early_eof == "goose pipe EOF after 0/1 bytes", early_eof

    read_pipe = Mock()
    read_pipe.read.side_effect = OSError("read failed")
    expired_read_error = expect_pipe_error(
        read_pipe, remaining=[1.0, 0.0], select_side_effect=([[read_pipe], [], []],)
    )
    assert expired_read_error == "CASE_TIMEOUT", expired_read_error

    early_read_error = expect_pipe_error(
        read_pipe, remaining=[1.0, 1.0], select_side_effect=([[read_pipe], [], []],)
    )
    assert early_read_error.startswith("goose pipe read failed:"), early_read_error

    early_select_error = expect_pipe_error(
        object(), remaining=[1.0, 1.0], select_side_effect=OSError("select failed")
    )
    assert early_select_error.startswith("goose pipe select failed:"), early_select_error
    print("ok: select/read/EOF deadline races preserve pre-deadline pipe errors")


def test_recv_admission_cap() -> None:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    server_errors: list[BaseException] = []

    def serve() -> None:
        try:
            conn, _ = listener.accept()
            with conn:
                conn.sendall(bytes(range(64)))
                time.sleep(0.1)
        except BaseException as exc:  # surfaced after join in this test thread
            server_errors.append(exc)
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    child = """
import sys
r, w = sys.stdin.buffer, sys.stdout.buffer
def send(kind, payload=b''):
    w.write(bytes([kind, len(payload) >> 8, len(payload) & 255]) + payload); w.flush()
send(2, b'\\x00\\x04')
header = r.read(3)
assert header == bytes([10, 0, 4]), header
data = r.read(4)
assert data == bytes([0, 1, 2, 3]), data
send(3, b'recv=4')
send(4, b'\\x00')
"""
    try:
        code, events, close = run_bridge(
            python_child(child), "127.0.0.1", port, case_timeout_s=2.0
        )
    finally:
        thread.join(timeout=2)
        listener.close()
    assert not thread.is_alive() and not server_errors, server_errors
    assert (code, events, close) == (0, ["recv=4"], None)
    print("ok: RECV IPC request admits only its declared four-byte cap")


def test_child_deadline_and_reap() -> None:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    accepted: list[socket.socket] = []

    def accept_only() -> None:
        try:
            conn, _ = listener.accept()
            accepted.append(conn)
        finally:
            listener.close()

    thread = threading.Thread(target=accept_only, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="honkmqtt-resource-") as tmp:
        pidfile = str(Path(tmp) / "child.pid")
        child = "import os,sys,time; open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(30)"
        started = time.monotonic()
        try:
            run_bridge(python_child(child, pidfile), "127.0.0.1", port, case_timeout_s=0.35)
        except BridgeError as exc:
            assert str(exc) == "CASE_TIMEOUT", exc
        else:
            raise AssertionError("silent child should hit the case deadline")
        elapsed = time.monotonic() - started
        assert elapsed < 2.0, f"deadline took {elapsed:.2f}s"
        pid = int(Path(pidfile).read_text(encoding="ascii"))
        if os.name == "posix":
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f"timed-out Goose child {pid} still exists")
    thread.join(timeout=1)
    for conn in accepted:
        conn.close()
    print(f"ok: child deadline fires in {elapsed:.2f}s and reaps the child")


def main() -> None:
    test_ipc_limit()
    test_read_exact_deadline_races()
    test_recv_admission_cap()
    test_child_deadline_and_reap()
    print("tcp resource smoke: PASS")


if __name__ == "__main__":
    main()
