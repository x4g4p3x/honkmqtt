# M3 in-process transport regression

`tests/transport.goose` replays 145 fixed bytes through the caller-owned
buffers in `examples/stream/stream.goose`. The six frames are PINGREQ,
QoS 0 PUBLISH on topic `t` with a 125-byte binary payload, PUBACK, PINGREQ,
PUBACK, and DISCONNECT. The frame boundaries are `0, 2, 133, 137, 139, 143,
145`. MQTT 3.1.1 §2.2.2 defines the packet-type flags and §2.2.3 explains why
the PUBLISH Remaining Length of 128 uses `80 01`. Both bytes and offsets are
specified independently of the codec. [OASIS MQTT 3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html)

Each of 128 replays uses Goose `std.rng` seeded with `20261127 + case_index`
(starting at zero). Each turn draws a read cap of 0–16 bytes and a write cap
of 0–5 bytes. The replay checks the exact RX and TX windows, cursor changes,
zero bytes consumed on incomplete input, all-or-nothing enqueue under TX
backpressure, and the full bytes received by the simulated sink. Each replay
has an assertion limit of 580 turns and 16 consecutive turns without a new
read, frame commit, or write. RX capacity is 133 bytes, from `128 + HEADER_MAX`,
and TX capacity is 131 bytes. The independent sink holds 145 bytes.

The same PUBLISH header in an RX window after a consumed frame returns
`INCOMPLETE` with a body cap of 128 and `INVALID` with a cap of 127 before any
PUBLISH body bytes arrive. Both results consume zero bytes and leave the RX
bytes and tail sentinel intact. Existing transport fixtures cover malformed
framing, clean and truncated EOF, RX `NO_SPACE`, and resuming reads
after a full RX buffer is consumed.

## Local verification

Validated from base `3c77de90a97aea138b5ac4205400efb5c71b3b54` with the
transport regression applied. Both hosts used Goose v2026.4, runtime
`dce889723a23`.

| Host | Python | Native C toolchain selected by `goose toolchain` |
| --- | --- | --- |
| Windows x64, build `10.0.26300.0` | 3.14.10 | Clang 14.0.6 (`clang-14.0.6-1591fbf5`) |
| Ubuntu 24.04.5 LTS x86_64, WSL2 | 3.12.3 | GCC 13.3.0 (`gcc-13.3.0-a920ca84`) |

Run from the repository root with the Windows Goose executable on `PATH`.
Set `GOOSE` to its path to pin the Python runner's executable.

```powershell
$env:GOOSE = (Get-Command goose).Source
goose --version
goose toolchain
python scripts/lint.py
python scripts/test_selftest.py
python scripts/test.py --native --require-native
goose examples/transport.goose
```

Run in an Ubuntu-24.04 WSL Linux checkout with the same sources.

```sh
export GOOSE=/root/goose-v2026.4/goose-v2026.4-linux-x64/goose
export PATH="$(dirname "$GOOSE"):$PATH"
goose --version
goose toolchain
python3 scripts/lint.py
python3 scripts/test_selftest.py
python3 scripts/test.py --native --require-native
goose examples/transport.goose
```

Lint, the runner self-test, all 13 programs in normal, debug and native modes,
and the transport example passed on both hosts. All six host/mode combinations
printed identical replay counters. The 18,560 bytes are checked in each
direction across the 128 replays.

```text
Transport replay seed=20261127 cases=128 frames=768 bytes=18560 peak_rx=131 peak_tx=131 peak_turns=91 peak_idle=6
Transport replay incomplete=1950 rx_wait=116 rx_compact=128 tx_blocked=250 tx_wait=1278 tx_short=6009 tx_compact=511
```

`peak_rx` and `peak_tx` count live bytes (`end - start`). RX peaked at
131 of 133 allocated bytes, and TX peaked at 131 of 131. `peak_turns` and
`peak_idle` are maxima over individual replays. The second line totals events
across the campaign. `tx_wait` counts zero-cap drain calls with pending bytes.

The same test now adds a second reproducible campaign of **64** independently
assembled valid streams using seed `20261128 + case_index`. Each stream contains
1–24 frames chosen from independent MQTT wire vectors for PINGREQ, PINGRESP,
DISCONNECT, two PUBACK identifiers, CONNACK, and a QoS 0 PUBLISH. Read caps
vary from 1–11 bytes; the 32-byte RX array is drained as complete frames are
accepted. The default run reports 773 frames / 2,694 bytes, a 32-byte peak RX
window, and 28 incomplete-frame observations. Expected bytes are assembled from
the literal vector table; the two PUBACK variants are also checked with the
typed parser. Separate tests pin zero-consumption behavior for a truncated
remaining-length continuation and a four-byte maximum remaining length rejected
against a 128-byte body cap, with sentinels checked after each input.

`examples/tcp/test_resources.py` is a controlled loopback-only resource smoke
check. It verifies that IPC rejects payload lengths above 512 bytes, a RECV
request for four bytes admits only four bytes from a socket with more data, and
a silent fake Goose child is killed and reaped at a 0.35-second case deadline.
It also checks the declared errors for a watchdog-interrupted pipe read. Run it
with `python3 examples/tcp/test_resources.py`; it does not start a broker or
contact an external host.

## Remaining M3 work

The seeded replay varies the I/O schedule over one fixed byte stream; the
additional campaign varies frame order, frame count, and read fragmentation
over a bounded set of valid wire vectors. This remains a deterministic smoke
campaign, not fuzzing, exhaustive sequence coverage, a memory-safety proof, or
an MQTT conformance result. The TCP smoke covers one loopback read cap, an IPC
size boundary, and one silent-child deadline path; it does not characterize
resource use under load or every cleanup/error branch. Representative end-to-end
throughput, latency, memory, runtime configuration, and variability remain
unmeasured.
The separate loopback broker evidence comes from PR #16. [TCP interop record](../tcp/INTEROP.md)
