# HonkMQTT

**MQTT speaks Goose.**

HonkMQTT is an experimental, transport-independent MQTT 3.1.1 framing and topic-filter library written in Goose. It has no C source or third-party library dependencies. Goose's native executable toolchain itself uses C; this is not a claim that generated executables or the Goose runtime contain no C.

## Status

This is an early foundation, **not a complete MQTT client or a complete MQTT 3.1.1 implementation**. It provides:

- Fixed-header parsing with bounded MQTT remaining lengths, flag checks, and incremental frame detection. Incomplete frames consume no bytes.
- Encoding an opaque body into a caller-provided buffer.
- Zero-copy parsing of MQTT 3.1.1 PUBLISH frames, including topic and packet
  identifier validation.
- UTF-8 and topic name/filter checks, including wildcard matching and the `$` topic rule.

It does **not** parse or validate other packet bodies, validate application payloads, implement QoS/session state, perform network I/O, support MQTT 5 properties, or claim protocol conformance. It rejects non-minimal remaining-length encodings. Applications must validate other packet bodies before acting on untrusted data. The UTF-8 checks enforce well-formed Unicode scalar values and exclude U+0000; they do not reject additional code points discouraged by MQTT. Do not use this as a security boundary or production MQTT implementation yet.

The fixed-header and frame functions accept `const u8[:]` and return status codes; `frame` reports how many bytes to consume only on success. Keep incomplete input in your own bounded buffer and retry after receiving more data. Supply a maximum permitted body size to `frame` to limit buffering. `encode` requires a non-overlapping output buffer. The library never owns the transport.

`publish(input, max_body)` accepts a complete or partial MQTT 3.1.1 PUBLISH
frame and returns `(status, consumed, topic_offset, topic_length,
payload_offset, packet_identifier)`. On success, the topic is
`input[topic_offset..topic_offset + topic_length]` and the payload is
`input[payload_offset..consumed]`; these refer to the original input, which
must remain available. The identifier is zero for QoS 0 and nonzero for QoS 1
or 2. It checks the frame flags, nonempty UTF-8 topic without wildcards, and
identifier when required. It does not interpret the payload or enforce protocol
session rules. Non-PUBLISH packets, malformed bodies, and lengths over
`max_body` return `INVALID`; truncated frames return `INCOMPLETE`. All other
return values are zero on failure, and trailing frames are left unconsumed.

## Use

Install [Goose](https://github.com/aardappel/goose) v2026.4 or newer. Pin a commit or release tag when consuming this pre-release library. For local development:

```goose
import honkmqtt from "../honkmqtt";

fn main() {
    let status, count = honkmqtt::frame([0xc0, 0x00], 1024);
    assert(status == honkmqtt::OK && count == 2);
    assert(honkmqtt::matches("sensors/+/temp", "sensors/kitchen/temp"));
}
```

From a project elsewhere, the import can use `"x4g4p3x/honkmqtt@<commit>"`. See [Goose package documentation](https://aardappel.github.io/goose/docs/packages.html) for pinned Git imports and updates.

```sh
python scripts/lint.py
python scripts/test.py
python scripts/test.py --native --require-native
```

`scripts/test.py` is the single repeatable test entry point. It runs
`tests/test.goose`, `tests/publish.goose`, `tests/coverage.goose`,
`tests/api.goose`, and `tests/fuzz.goose` in the Goose in-process runner, both
normally and with `--debug`. With `--native` it also `goose build`s and
executes those programs when `goose toolchain` reports a C compiler;
`--require-native` fails if that path is skipped. Toolchain launch failures,
nonzero exits, and unrecognized output are errors (not a successful skip).
Native mode aborts a target if the previous executable cannot be removed. Run
`python scripts/test_selftest.py` for those regression checks. Individual
`goose tests/...` and `goose build tests/...` commands remain valid.

`tests/api.goose` is the behavioral matrix for every public operation and its
documented failure statuses (`header`/`frame`/`encode`/`publish` status codes
and the boolean UTF-8/topic/filter/`matches` contracts), including unchanged
output on `encode` failure. `tests/coverage.goose` remains a combinatorial
flags/length exercise; it is **not** measured line coverage. Goose v2026.4
exposes no source-mapped coverage or instrumentation command in `goose help` /
`goose help --man`, so this repository does not report a coverage percentage.

### Randomized smoke (fuzz)

`tests/fuzz.goose` is a reproducible bounded smoke campaign (default seed
`20261116`, default `10000` cases) over `header`/`frame`/`publish`/`encode`
and UTF-8/topic/filter/`matches`, with saved fixed regressions and
deterministic generated flag/length/UTF-8/wildcard/truncation cases first.
Override with:

```sh
goose tests/fuzz.goose -- 20261116 10000
```

Record the printed seed and case count. On failure under `--debug`, add a
minimal fixed vector to the `saved_regressions` section. This is a minimum
smoke campaign, not a coverage claim, AFL/libFuzzer replacement, memory-safety
proof, or MQTT conformance result. Buffers are capped (48-byte random inputs);
it does not explore multi-megabyte remaining lengths.

Run `python scripts/lint.py` to check Goose formatting and compiler
diagnostics across the repository. It requires Python 3 and Goose on PATH;
set `GOOSE` to the executable path if needed. Fix formatting with
`goose format .`.

### Supported CI targets

GitHub Actions CI (`.github/workflows/ci.yml`) pins Goose **v2026.4** and runs
lint, interpreter tests, and native build/run on:

| OS image | Arch | Goose | Native C compiler expectation |
| --- | --- | --- | --- |
| `ubuntu-24.04` | x64 | v2026.4 | `gcc` installed in the Linux CI job; selected via `goose toolchain` |
| `windows-2022` | x64 | v2026.4 | MSVC via `msvc-dev-cmd` in the Windows CI job, with `GOOSE_CC=msvc` |

Other hosts are unsupported until they have the same automated evidence. Local
native builds may use any C compiler Goose accepts (`msvc`, `clang-cl`,
`clang`, `gcc`, or `cc`, or `GOOSE_CC` / `--cc`). Record the exact
`goose toolchain` output when comparing results. `scripts/test.py --native`
deletes each target's previous build product before building so a stale
executable cannot satisfy a no-op or failed build. Goose's in-process runner
needs no separate C compiler. The tests are deterministic software checks, not
an interoperability or conformance suite. The protocol reference is the
[OASIS MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

### Optimized-build baselines

Use `python scripts/bench.py --warmup 1 --samples 7` to build `-O2` natives,
discard warmup, and record at least seven serialized steady-state samples for:

| Workload | Source | What it measures | Expected checksum |
| --- | --- | --- | --- |
| `encode_frame_match` | `tests/benchmark.goose` | 1e6 encode+frame + alternating topic matches | `16500000` |
| `publish_parse` | `tests/bench_publish.goose` | 1e6 `publish` parses of a fixed QoS 1 vector | `4679000000` |

Timing boundary: each program prints `steady_seconds` from Goose `clock()`
around the timed loop only (process startup excluded). The runner checks
checksums and prints raw samples plus min/median/max/mean; it does **not**
assert wall-clock budgets. Manual single runs remain valid, for example:

```sh
goose build -O2 tests/benchmark.goose
./tests/benchmark "sensor reading" "sensors/+/temperature" "sensors/kitchen/temperature" "sensors/kitchen/humidity"
goose build -O2 tests/bench_publish.goose
./tests/bench_publish
```

A recorded local Windows x64 capture (machine, toolchain, raw samples, limits)
is in [baselines/m0-local-windows.md](baselines/m0-local-windows.md). These
workloads use short fixed inputs and no network I/O; they are not a general
throughput, latency SLA, or safety assessment.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the proposed MQTT 3.1.1 codec milestones,
acceptance criteria, and later product decisions. Contributions are welcome.

MIT licensed; see [LICENSE](LICENSE).
