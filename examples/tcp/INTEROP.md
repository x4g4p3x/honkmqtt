# M3 TCP broker interop (evidence)

HonkMQTT core stays transport-free. Goose has no TCP API, so this slice uses an
**honest bridge architecture**:

```
MQTT broker (loopback)
    ↑ TCP — Python owns connect / short recv / one send() per drain /
            timeouts / EOF|RESET|TIMEOUT classification
examples/tcp/bridge.py
    ↑ length-prefixed IPC: SEND→ack(u16 sent), RECV→bytes|ERR
examples/tcp/session.goose
    → stream::feed / frame / commit_rx
    → stream::enqueue / drain / commit_tx(exact send ack)
    → honkmqtt typed codecs
```

Python never frames MQTT and never acknowledges bytes that `socket.send` did
not accept. Goose commits TX only for the acked count and feeds RX only up to
`min(64, rx_free)`.

This is interoperability evidence, not certification or a stable network stack.

## Bounds / quotas / timeouts

| Limit | Value |
|-------|------:|
| RX capacity | 256 |
| TX capacity | 256 |
| `max_body` | 251 (`RX - HEADER_MAX`) |
| Recv request | `min(64, RX free capacity)` |
| IPC payload max | 512 |
| TCP connect timeout | 2.0 s (also capped by remaining case time) |
| Socket I/O timeout | `min(2.0 s, remaining case time)` |
| Per-case wall timeout | 15.0 s (watchdog kills Goose child / unblocks pipe) |
| Send ack | one `socket.send`; reply u16be count |

## Brokers and prerequisites

| Component | Version / note |
|-----------|----------------|
| Eclipse Mosquitto | **2.0.18** (`2.0.18-1build3`, apt) |
| Aedes | **0.51.3** (pinned in `brokers/package.json` + lockfile) |
| Node (WSL) | v18.19.1 (Linux; do not mix Windows `node.exe` with WSL loopback) |
| Goose | v2026.4 |
| Python | 3.x |

**System Mosquitto service:** `apt install mosquitto` postinst enabled
`mosquitto.service`. This task **stopped and disabled** that unit so only
harness-owned ephemeral `127.0.0.1` listeners run (`mosquitto -c` / Aedes child
in a `TemporaryDirectory`, cleaned up on exit). Unrelated processes were left
alone. Confirm: `systemctl is-enabled/is-active mosquitto` → `disabled` /
`inactive`.

Ephemeral Mosquitto config from `brokers/mosquitto.conf.in` (template SHA-256
`897c76cfb87479d96d67651116d914a83a2b686b2c71b308ce85247cd4973c3b`); runtime
file substitutes `@PORT@`. Aedes entrypoint SHA-256
`819b586d1f34113f30a9a49f700a475e8e0ab4dfd62b9e2bacadf5b9f50a6f3d`.

## Reproduction

```bash
# WSL/Linux: goose, python3, mosquitto, node+npm on PATH
systemctl stop mosquitto 2>/dev/null; systemctl disable mosquitto 2>/dev/null
cd examples/tcp/brokers && npm install --no-fund --no-audit && cd ../../..
python3 examples/tcp/run_interop.py --goose goose --json-out examples/tcp/interop_results.json
```

## Case matrix (recorded after acceptance fixes)

| Broker | Scenario | Result | Peer close |
|--------|----------|--------|------------|
| mosquitto 2.0.18 | positive | PASS | — |
| mosquitto 2.0.18 | malformed | PASS | **EOF** |
| mosquitto 2.0.18 | reconnect | PASS | — |
| aedes 0.51.3 | positive | PASS | — |
| aedes 0.51.3 | malformed | PASS | **EOF** |
| aedes 0.51.3 | reconnect | PASS | — |

**positive:** CONNECT→CONNACK (`session=0 code=0`), SUBSCRIBE id=7→SUBACK
`code=0`, PUBLISH QoS0, **typed inbound PUBLISH verified**
`topic=m3/t payload=hi!` (same-client delivery), PINGREQ→PINGRESP, DISCONNECT.

**malformed:** reserved type `0x00 0x00` via stream enqueue/drain/send-ack;
PASS requires confirmed **EOF or RESET** (TIMEOUT/other fail); no PINGRESP
before close; then **same client-id reconnect** (CONNACK/PING/DISCONNECT).
Both brokers closed with **EOF** in this run (no RESET/TIMEOUT observed).

**reconnect:** graceful DISCONNECT then fresh TCP + same client id.

## Limitations

- Not sockets inside Goose; WSL must use Linux Node/Mosquitto for loopback.
- QoS1/2, auth, TLS, MQTT 5, multi-client fan-out out of scope.
- Malformed coverage is one reserved-type probe, not a full adversarial corpus.
- Passing this matrix is not MQTT conformance certification.
