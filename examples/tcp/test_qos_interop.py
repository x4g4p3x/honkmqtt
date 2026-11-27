#!/usr/bin/env python3
"""Scripted loopback checks for the QoS example driver using literal MQTT bytes."""

import os
import socket
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from bridge import BridgeError, run_bridge
from run_interop import qos_events_ok

SESSION = Path(__file__).with_name("session.goose")
CONNECT = bytes.fromhex("10 13 00 04 4d 51 54 54 04 02 00 1e 00 07") + b"fixture"
CONNACK = bytes.fromhex("20 02 00 00")
SUBSCRIBE = bytes.fromhex("82 09 00 07 00 04") + b"m3/t"
SUBACK = bytes.fromhex("90 03 00 07")
PUBLISH_BODY = bytes.fromhex("0b 00 04") + b"m3/t" + bytes.fromhex("12 34") + b"hi!"
PUBREC = bytes.fromhex("50 02 12 34")
PUBREL = bytes.fromhex("62 02 12 34")
PUBCOMP = bytes.fromhex("70 02 12 34")
UNSUBSCRIBE = bytes.fromhex("a2 08 00 08 00 04") + b"m3/t"
UNSUBACK = bytes.fromhex("b0 02 00 08")
DISCONNECT = bytes.fromhex("e0 00")


class QosInteropTest(unittest.TestCase):
    def expect_bytes(self, peer, expected):
        received = bytearray()
        while len(received) < len(expected):
            chunk = peer.recv(len(expected) - len(received))
            if not chunk:
                self.fail(f"EOF before receiving {expected.hex(' ')}")
            received.extend(chunk)
        self.assertEqual(received, expected)

    def exchange(self, qos, script):
        native = os.environ.get("HONKMQTT_NATIVE_SESSION")
        args = [f"qos{qos}", "fixture"]
        if native:
            cmd = [native, *args]
        else:
            cmd = [os.environ.get("GOOSE", "goose"), str(SESSION), "--", *args]
        publish = bytes([0x30 + 2 * qos]) + PUBLISH_BODY

        with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as worker:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)

            def serve():
                peer, _ = listener.accept()
                with peer:
                    peer.settimeout(5)
                    self.expect_bytes(peer, CONNECT)
                    peer.sendall(CONNACK)
                    self.expect_bytes(peer, SUBSCRIBE + bytes([qos]))
                    peer.sendall(SUBACK + bytes([qos]))
                    self.expect_bytes(peer, publish)
                    script(peer, publish)

            server = worker.submit(serve)
            try:
                return run_bridge(cmd, "127.0.0.1", listener.getsockname()[1], case_timeout_s=10)
            finally:
                server.result(timeout=7)

    def test_qos2_interleaves_and_reuses_id_in_opposite_directions(self):
        def script(peer, publish):
            # The echo uses the same numeric id in the other direction.
            peer.sendall(publish + PUBREC[:1])
            self.expect_bytes(peer, PUBREC)
            # Finish the publisher's PUBREC and append the subscriber's PUBREL.
            peer.sendall(PUBREC[1:] + PUBREL)
            self.expect_bytes(peer, PUBREL + PUBCOMP)
            peer.sendall(PUBCOMP)
            self.expect_bytes(peer, UNSUBSCRIBE)
            peer.sendall(UNSUBACK)
            self.expect_bytes(peer, DISCONNECT)

        status, events, peer_close = self.exchange(2, script)
        self.assertEqual(status, 0)
        self.assertIsNone(peer_close)
        self.assertTrue(qos_events_ok("qos2", events), events)

    def test_qos1_rejects_wrong_puback_id(self):
        def script(peer, _):
            peer.sendall(bytes.fromhex("40 02 12 35"))

        with self.assertRaisesRegex(BridgeError, "^goose fatal: publish acknowledgement id mismatch$"):
            self.exchange(1, script)

    def test_qos2_rejects_pubcomp_before_pubrec(self):
        def script(peer, _):
            peer.sendall(PUBCOMP)

        with self.assertRaisesRegex(BridgeError, "^goose fatal: unexpected packet during QoS exchange$"):
            self.exchange(2, script)

    def test_qos1_rejects_eof_mid_acknowledgement(self):
        def script(peer, _):
            peer.sendall(bytes.fromhex("40 02 12"))
            peer.shutdown(socket.SHUT_WR)

        with self.assertRaisesRegex(BridgeError, "^goose fatal: EOF before complete MQTT frame$"):
            self.exchange(1, script)


if __name__ == "__main__":
    unittest.main()
