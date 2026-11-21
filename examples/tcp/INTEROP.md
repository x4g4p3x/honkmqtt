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
| Recv request | `min(64, free RX tail)`; compact when tail full; reset empty window at capacity |
| IPC payload max | 512 |
| TCP connect timeout | `min(2.0 s, remaining)`; **fail** if remaining ≤ 0 (no fresh 2s fallback) |
| Socket I/O timeout | `min(2.0 s, remaining case time)` |
| Per-case wall timeout | 15.0 s (watchdog kills Goose child / unblocks pipe) |
| Send ack | one `socket.send`; reply u16be count |
| Peer close | drain all complete buffered frames before RECV/EOF; bridge EOF/RESET only |
| Aedes ready | `wait_port` + `child.poll` (≤5 s); kill/reap + stderr on failure |

## Brokers and prerequisites

| Component | Version / note |
|-----------|----------------|
| Eclipse Mosquitto | **2.0.18** (`2.0.18-1build3`, apt) |
| Aedes | **0.51.3** (pinned in `brokers/package.json` + `package-lock.json`) |
| Python | **3.12.3** (`3.12.3 (main, Jul 15 2026, 23:46:41) [GCC 13.3.0]`) |
| Node | **v18.19.1** |
| npm | **9.2.0** |
| Goose | **goose v2026.4 (runtime dce889723a23)** |
| OS | **Linux … WSL2 x86_64** (`meta.toolchain.os_uname` in JSON) |

Exact strings for the committed run are also in
`examples/tcp/interop_results.json` → `meta.toolchain`.

**Historical note (this development machine only):** installing Mosquitto via
`apt` enabled `mosquitto.service` through the package postinst. The worker that
set up this environment **stopped and disabled that newly installed system
unit** so it would not compete on port 1883. Ephemeral harness listeners do
**not** require stopping or disabling a system broker; the runner never manages
`systemd` units. Leave any pre-existing Mosquitto install as you found it.

Ephemeral Mosquitto config from `brokers/mosquitto.conf.in` (template SHA-256
`897c76cfb87479d96d67651116d914a83a2b686b2c71b308ce85247cd4973c3b`); runtime
file substitutes `@PORT@`. Aedes entrypoint SHA-256 is recorded per run in
`interop_results.json` (`broker_conf_sha256` for aedes rows).

## Reproduction

```bash
# WSL Ubuntu-24.04 (default user root):
export GOOSE=/root/goose-v2026.4/goose-v2026.4-linux-x64/goose
# Fresh Aedes parent (runner creates an owned child TemporaryDirectory under it):
export HONKMQTT_AEDES_NPM=$(mktemp -d)
# Clean Mosquitto: apt-get download + dpkg-deb -x (no dpkg -i; system unit untouched)
python3 examples/tcp/run_interop.py --goose "$GOOSE" --extract-mosquitto \
  --json-out examples/tcp/interop_results.json
```

`--extract-mosquitto` runs `apt-get download mosquitto=2.0.18-1build3` then
`dpkg-deb -x` into a fresh work directory and prepends that tree's
`usr/sbin` (or `usr/bin`) to `PATH`. Provenance lands in
`meta.mosquitto_provenance`. Without the flag, the host `PATH` binary is
recorded as reused.

Aedes always gets `npm ci --no-fund --no-audit` from the pinned
`brokers/package-lock.json` into an **owned** `TemporaryDirectory` (optional
`HONKMQTT_AEDES_NPM` is only the parent). The install lives for the whole
six-case matrix, then that directory alone is cleaned. Provenance:
`meta.aedes_provenance`. Readiness is `wait_port` + `child.poll`.

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

Source hashes for the committed run: see `meta.session_sha256`,
`meta.bridge_sha256`, and `meta.stream_sha256` in `interop_results.json`.

## Limitations

- Not sockets inside Goose; WSL must use Linux Node/Mosquitto for loopback.
- QoS1/2, auth, TLS, MQTT 5, multi-client fan-out out of scope.
- Malformed coverage is one reserved-type probe, not a full adversarial corpus.
- Passing this matrix is not MQTT conformance certification.
