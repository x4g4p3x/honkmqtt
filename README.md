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
`tests/test.goose`, `tests/publish.goose`, and `tests/coverage.goose` in the
Goose in-process runner, both normally and with `--debug`. With `--native` it
also `goose build`s and executes those programs when `goose toolchain` reports
a C compiler; `--require-native` fails if that path is skipped. Individual
`goose tests/...` and `goose build tests/...` commands remain valid.

Run `python scripts/lint.py` to check Goose formatting and compiler
diagnostics across the repository. It requires Python 3 and Goose on PATH;
set `GOOSE` to the executable path if needed. Fix formatting with
`goose format .`.

### Supported CI targets

GitHub Actions CI (`.github/workflows/ci.yml`) pins Goose **v2026.4** and runs
lint, interpreter tests, and native build/run on:

| OS image | Arch | Goose | Native C compiler expectation |
| --- | --- | --- | --- |
| `ubuntu-24.04` | x64 | v2026.4 | `gcc` installed in CI; selected via `goose toolchain` |
| `windows-2022` | x64 | v2026.4 | MSVC via `msvc-dev-cmd`, with `GOOSE_CC=msvc` |

Other hosts are unsupported until they have the same automated evidence. Local
native builds may use any C compiler Goose accepts (`msvc`, `clang-cl`,
`clang`, `gcc`, or `cc`, or `GOOSE_CC` / `--cc`). Record the exact
`goose toolchain` output when comparing results. `scripts/test.py --native`
deletes each target's previous build product before building so a stale
executable cannot satisfy a no-op or failed build. Goose's in-process runner
needs no separate C compiler. The tests are deterministic software checks, not
an interoperability or conformance suite. The protocol reference is the
[OASIS MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

For a small repeatable performance workload, build `tests/benchmark.goose` in
release mode and time the resulting executable repeatedly, for example:

```sh
goose build tests/benchmark.goose
./tests/benchmark "sensor reading" "sensors/+/temperature" "sensors/kitchen/temperature" "sensors/kitchen/humidity"
```

On Windows use `tests/benchmark.exe`. Each run performs one million encodes,
frame checks, and topic matches and prints a checksum (16500000 for these
inputs). It exercises a single short body and two ASCII topics, with no network
I/O; it is not a general throughput or safety assessment. Compare repeated
timings on the same machine, compiler, build options, and inputs, and verify
correctness separately.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the proposed MQTT 3.1.1 codec milestones,
acceptance criteria, and later product decisions. Contributions are welcome.

MIT licensed; see [LICENSE](LICENSE).
