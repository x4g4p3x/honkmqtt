# M3 loopback broker publish/receive baseline

Captured 2026-11-27 from the benchmark worktree based on `3c77de90`, with
the measured implementation recorded in `45d4fb1`. The
machine-readable [raw record](m3-broker-loopback.json) contains seven batch
samples per broker and payload size, all 28,000 per-echo latency samples,
sampled RSS, source SHA-256 identities, broker configuration identities,
toolchain selection and the native executable hash.

## Workload and timing

Native Goose `examples/tcp/session.goose` connects with Clean Session,
subscribes to `m3/t` at QoS 0, and publishes then receives its own QoS 0 echo.
The 16-byte and 192-byte payloads include a unique per-exchange sequence and
deterministic remaining bytes. Goose parses each echoed PUBLISH and checks its
topic, payload length, sequence and every payload byte before it completes an
exchange. An earlier echo cannot satisfy a later operation.

Each broker/size pair ran one discarded batch of 100 echoes followed by seven
serialized retained batches of 1,000 echoes. Each connection had 30 warmup
echoes before its batch. The adapter bounds were RX=256, TX=256, `max_body=251`,
`recv_max=64` and bridge IPC max=512 bytes. Cases are fixed to those two
payload sizes; the runner caps samples at 20, measured exchanges at 1,000 and
warmups at 50. A bridge batch watchdog is 60 seconds and the outer batch
subprocess timeout is 90 seconds.

Goose `clock_ns()` records start immediately before payload generation and
PUBLISH encoding, then end after the echoed frame has been parsed, verified and
committed to the RX stream. It buffers these ticks and emits the timing records
after the measured loop, so event IPC does not sit inside each publish/echo
interval. The interval from first start to last end gives batch throughput.
Messages/s counts exchanges; payload bytes/s counts application payload only.
Compile, npm install, broker startup, TCP connect, MQTT CONNECT/SUBSCRIBE and
per-connection warmup are outside the measured loop.

## Results

Throughput is the median of seven batch rates, with observed min–max. Median
latency is the median of the seven per-batch latency medians, with their
min–max in parentheses. P95 is the median of the seven per-batch p95 latencies.
RSS is the min–max across batches of the highest combined sum in a nominal
1 ms sampling round, in KiB.

| Broker | Payload | Throughput (messages/s) | Median echo latency (µs) | P95 echo latency (µs) | Highest sampled combined RSS sum (KiB) |
|---|---:|---:|---:|---:|---:|
| Mosquitto 2.0.18 | 16 B | 5,611 (5,563–5,703) | 156 (153–160) | 273 | 25,284–25,336 |
| Mosquitto 2.0.18 | 192 B | 1,536 (1,517–1,604) | 628 (604–643) | 819 | 25,308–25,416 |
| Aedes 0.51.3 | 16 B | 5,173 (4,236–5,259) | 173 (164–215) | 308 | 93,156–94,232 |
| Aedes 0.51.3 | 192 B | 1,482 (1,466–1,507) | 654 (644–664) | 853 | 96,692–100,060 |

See the JSON for each raw throughput result, latency sample and separate bridge,
Goose-child and broker RSS observations.

## Environment and reproduction

- Ubuntu 24.04.5 LTS under WSL2, Linux 6.18.58.1, x86_64; AMD Ryzen 5 8600G.
- Goose v2026.4 (`dce889723a23`), native `-O2` build.
- `goose toolchain`: GCC 13.3.0 selected from PATH, `/usr/bin/cc`, style `cc`,
  compiler id `gcc-13.3.0-a920ca84`.
- Python 3.12.3; Node 18.19.1; npm 9.2.0.
- Mosquitto 2.0.18 and lockfile-pinned Aedes 0.51.3. Aedes dependencies are
  installed with `npm ci` in an owned temporary directory. Both brokers use
  ephemeral loopback listeners. The runner does not manage OS services.

From the repository root in WSL Ubuntu 24.04:

```bash
export GOOSE=/path/to/goose-v2026.4-linux-x64/goose
python3 examples/tcp/bench_run.py --json-out /tmp/honkmqtt-broker-baseline.json
```

The capture records SHA-256 identities for the Goose session, bridge, runner,
shared broker setup helper, core and stream modules, Mosquitto config, and Aedes
server/package manifest/lockfile. It also records the compiled native binary
hash.

## Limits

This is an end-to-end baseline for the named loopback brokers, Goose stream
adapter and Python TCP bridge. The timing includes Python IPC, socket calls,
broker work and Goose codec/adapter work; it is not a library-only benchmark.
Only CONNECT, SUBSCRIBE, QoS 0 PUBLISH echo and DISCONNECT are exercised. It
says nothing about larger frames, QoS 1/2, fan-out, remote networks, bare-metal
Linux, other packet bodies, MQTT conformance or production readiness.

The RSS sampler reads each `/proc/<pid>/status` sequentially during nominal
1 ms polling rounds. The reported combined value is the maximum sum of those
page counts read in one round; it can include shared pages and miss transients,
so it is not a strict instantaneous or unique-memory peak. No speedup or
universal performance claim is made.
