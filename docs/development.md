# Development and verification

From a checkout, use Python 3 and Goose v2026.4 or newer. Put Goose on PATH
or set `GOOSE` to its executable. The in-process test runner needs no
separate C compiler. Native builds use the compiler reported by
`goose toolchain`.

## Run the checks

```sh
python scripts/lint.py
python scripts/test.py
python scripts/test.py --native --require-native
```

Lint checks Goose formatting and compiler diagnostics. Use `goose format .`
to format a checkout. The test runner launches 13 programs in normal and
`--debug` modes. `--native` also builds and runs them when a compiler is
available. `--require-native` makes a missing compiler a test failure.
Native mode removes prior output before building and requires a fresh
executable. Toolchain launch, exit, and parsing errors fail the run.

Run `python scripts/test_selftest.py` after changing the test runner.
For the TCP bridge resource checks, use `python3 examples/tcp/test_resources.py`
on Linux or WSL2.

## CI targets

CI pins Goose v2026.4 and runs lint, runner self-tests, both interpreter
modes, and native tests on these x64 targets.

| GitHub Actions image | Native C compiler |
| --- | --- |
| `ubuntu-24.04` | GCC. This job also runs the TCP bridge resource checks. |
| `windows-2022` | MSVC with `GOOSE_CC=msvc`. |

Use the same checks when adding a supported environment.
[CI workflow](../.github/workflows/ci.yml)

## Test coverage

| Area | Tests |
| --- | --- |
| Framing and topics | [Core tests](../tests/test.goose), [API status matrix](../tests/api.goose), and [combinatorial flags and lengths](../tests/coverage.goose) |
| PUBLISH | [Parse vectors](../tests/publish.goose) and [encode vectors](../tests/publish_encode.goose), including a 65,535-byte topic and rejection above that limit |
| Connections | [CONNECT](../tests/connect.goose) and [CONNACK](../tests/connack.goose) |
| Acknowledgements and subscriptions | [Publish acknowledgements](../tests/pubresp.goose), [SUBSCRIBE and SUBACK](../tests/subscribe.goose), and [UNSUBSCRIBE and UNSUBACK](../tests/unsubscribe.goose) |
| Empty control packets | [PINGREQ, PINGRESP, and DISCONNECT](../tests/empty_control.goose) |
| Stream handling | [Transport tests](../tests/transport.goose), [seeded replay evidence](../examples/stream/REGRESSION.md), and [broker cases](../examples/tcp/INTEROP.md) |

The suites check independent wire vectors, malformed and truncated input,
and unchanged encoder buffers on failure. The project reports behavioral
coverage. Goose v2026.4's documented CLI provides no source-mapped
coverage measurement.

### Seeded randomized checks

`tests/fuzz.goose` runs fixed regressions and generated boundary cases, then
a seeded campaign over framing, PUBLISH, and topic checks. The default is
10,000 randomized cases with seed `20261116` and inputs of up to 48 bytes.
To reproduce a run with explicit arguments:

```sh
goose run tests/fuzz.goose -- 20261116 10000
```

Record the printed seed and case count when reporting a failure. Reduce a
reproducible failure to a fixed case in `saved_regressions`.

### Maximum Remaining Length

The opt-in PUBLISH encode suite uses about 512 MiB for two buffers. It checks
the protocol maximum, rejection above it, and a short output view at the
maximum. Run it separately when changing the encoder's length arithmetic.

```sh
goose run tests/publish_encode_maxrl.goose
goose run tests/publish_encode_maxrl.goose --debug
```

See the native commands, results, and memory breakdown in the
[maximum-length record](../baselines/m1-encode-limits.md).

## Measure performance

Run the native microbenchmarks from a quiet checkout.

```sh
python scripts/bench.py --warmup 1 --samples 7
```

The runner builds at `-O2`, runs workloads serially, checks results, and
reports raw samples and summaries. Each timed loop uses runtime-varying
inputs and measures work after process startup.

| Workload | Measurement | Expected checksum |
| --- | --- | --- |
| `encode_frame_match` | One million encode, frame, and match iterations | `138498139` |
| `publish_parse` | One million PUBLISH parses over four cases | `17675999524` |
| `publish_encode` | One million PUBLISH encodes over four cases | `17860248136` |

The historical [M0 Windows](../baselines/m0-local-windows.md) and
[M0 WSL2](../baselines/m0-local-linux.md) captures cover framing and
PUBLISH parsing. The [M1 Windows](../baselines/m1-local-windows.md) and
[M1 WSL2](../baselines/m1-local-linux.md) captures cover PUBLISH encoding.

The [broker benchmark](../baselines/m3-broker-loopback.md) measures verified
QoS 0 publish/receive exchanges through the Goose adapter, Python bridge,
and loopback broker. It has its own reproduction commands, payload sizes,
memory methodology, and raw samples.

When evaluating a performance change, use the same platform, compiler,
build options, inputs, and timing boundary before and after. Record
`goose toolchain`, checksums, samples, and variability. Compare only
equivalent operations.

## Contribute a codec change

Preserve documented callers and buffer contracts. Cite the relevant MQTT
requirements, add independent wire vectors for new behavior, and run the
normal, debug, and native checks. Update the API reference for changes
callers can observe and record compatibility implications in the release
notes.

[Repository instructions](../AGENTS.md) · [Versioning policy](../VERSIONING.md)
