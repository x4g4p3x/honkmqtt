# M3 TCP broker interop (evidence)

HonkMQTT core stays transport-free. Goose has no TCP API, so this slice uses an
**honest bridge architecture**:

```
MQTT broker (loopback)
    ↑ TCP (Python owns connect / short I/O / timeouts / EOF|RESET|TIMEOUT)
examples/tcp/bridge.py
    ↑ length-prefixed stdin/stdout IPC (payload ≤ 512)
examples/tcp/session.goose
    → examples/stream feed/drain + honkmqtt typed codecs
```

This is interoperability evidence for MQTT 3.1.1 packet exchange, not
certification, security validation, or a stable network stack.

## Bounds

| Limit | Value |
|-------|------:|
| RX capacity | 256 |
| TX capacity | 256 |
| `max_body` | 251 (`RX - HEADER_MAX`) |
| Socket short-read / drain cap | 64 |
| IPC payload max | 512 |
| TCP connect timeout | 2.0 s |
| Socket I/O timeout | 2.0 s |
| Per-case wall timeout | 15.0 s |

Memory: fixed RX/TX arrays in Goose; bridge does not buffer unbounded socket
data (recv capped per turn).

## Brokers (pinned)

| Broker | Version | Role |
|--------|---------|------|
| Eclipse Mosquitto | **2.0.18** (Ubuntu `2.0.18-1build3`) | Independent C broker |
| Aedes | **0.51.3** (`examples/tcp/brokers/package.json`) | Independent Node broker |

Ephemeral loopback listeners only (`127.0.0.1`, free ports). Mosquitto config
from `brokers/mosquitto.conf.in` (template SHA-256
`897c76cfb87479d96d67651116d914a83a2b686b2c71b308ce85247cd4973c3b`); runtime
file substitutes `@PORT@`. Aedes entrypoint SHA-256
`819b586d1f34113f30a9a49f700a475e8e0ab4dfd62b9e2bacadf5b9f50a6f3d`.

Host for the recorded run: Ubuntu WSL2, Goose v2026.4, Node v18.19.1,
`python3`.

## Reproduction

```bash
# WSL/Linux with goose, python3, mosquitto, node+npm on PATH
cd examples/tcp/brokers && npm install --no-fund --no-audit && cd ../../..
python3 examples/tcp/run_interop.py --goose goose --json-out examples/tcp/interop_results.json
```

Optional single case:

```bash
# terminal A: mosquitto -c /tmp/mosq.conf   # listener 127.0.0.1:PORT
python3 examples/tcp/bridge.py --port PORT --goose goose \
  --session examples/tcp/session.goose --scenario positive --client-id honk-m3
```

Scenarios: `positive`, `malformed`, `reconnect`.

## Case matrix (recorded)

| Broker | Scenario | Result | Peer close class |
|--------|----------|--------|------------------|
| mosquitto 2.0.18 | positive | PASS | — |
| mosquitto 2.0.18 | malformed | PASS | **EOF** |
| mosquitto 2.0.18 | reconnect | PASS | — |
| aedes 0.51.3 | positive | PASS | — |
| aedes 0.51.3 | malformed | PASS | **EOF** |
| aedes 0.51.3 | reconnect | PASS | — |

**positive:** CONNECT→CONNACK (`session=0 code=0`), SUBSCRIBE id=7→SUBACK
`code=0`, PUBLISH QoS0 to `m3/t`, PINGREQ→PINGRESP, DISCONNECT. Inbound
broker PUBLISH (same-client delivery after subscribe) is skipped via typed
`publish` parse before expecting PINGRESP.

**malformed:** after CONNACK, send reserved type `0x00 0x00`; wait for peer
close. Bridge reports `EOF` / `RESET` / `TIMEOUT` distinctly (both brokers
observed **EOF** here—no RESET/TIMEOUT in this run).

**reconnect:** CONNECT/PING/DISCONNECT, TCP reconnect (`MSG_RECONNECT`), same
client id, CONNECT/PING/DISCONNECT again.

## Limitations

- Not sockets inside Goose; Windows Node must not be mixed with WSL loopback
  (use Linux `node`/`mosquitto` in WSL, or an all-Windows stack).
- QoS1/2 handshake, auth, TLS, MQTT 5, multi-client fan-out, and broker
  failover are out of scope.
- Malformed coverage is one reserved-type probe after a valid session—not a
  full adversarial corpus (see remaining M3 fuzz/DoS item).
- Passing this matrix is not MQTT conformance certification.
