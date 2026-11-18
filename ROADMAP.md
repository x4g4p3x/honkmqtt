# HonkMQTT roadmap

This is a proposed development plan, not a claim of protocol conformance or a
commitment to release dates. Work proceeds in small, independently testable
changes. Update milestone status and evidence as work lands; do not mark a
milestone complete merely because code exists.

## Direction and current baseline

The initial goal is a safe, fast, transport-independent **MQTT 3.1.1 packet
codec and topic-filter library for Goose**. Callers own buffers, transport,
and scheduling. A complete network client, broker, TLS, persistence, and
MQTT 5 are not part of the initial codec scope. Whether to build a client or
MQTT 5 support is a later product decision, not an implicit commitment.

As of M0 Exit on `cf8dbed`, M1 Exit on `fc12ece` (`encode_publish` baselines),
and the M2 PUBACK-family slice, the library has fixed-header parsing, bounded
frame detection, opaque-body encoding, PUBLISH parse/encode with limit vectors,
PUBACK/PUBREC/PUBREL/PUBCOMP parse/encode, UTF-8/topic validation, and
topic-filter matching. `scripts/test.py` is the repeatable local test entry
point; `.github/workflows/ci.yml` pins Goose v2026.4 and runs lint plus
interpreter and native tests on `ubuntu-24.04` and `windows-2022` (x64).
`tests/api.goose` states positive and failure-status cases for each public
operation. `tests/fuzz.goose` is a reproducible randomized smoke campaign
(default seed `20261116`, ≥10000 cases) with saved regressions and
deterministic generated boundaries. `scripts/bench.py` records optimized-build
steady-state samples for encode/frame/match, PUBLISH parse, and
`encode_publish` workloads with runtime-varying cases (anti-elision); local
captures are in `baselines/m0-local-*.md` and `baselines/m1-local-*.md`
(Ubuntu 24.04 under WSL2 for Linux). Goose v2026.4 has no source-mapped
coverage mechanism in its documented CLI, so there is no measured coverage
percentage. There is still no broker interoperability result or MQTT
conformance certification. The PUBLISH codec does not implement QoS or session
state.

## Milestones

### M0 — Reliable foundation (complete)

- [x] Provide a single repeatable test entry point and CI initially targeting
  Windows x64 and Linux x64 with Goose v2026.4 pinned; document C compiler
  versions and supported versions. Add other targets only with test evidence.
  Evidence: `scripts/test.py`; `.github/workflows/ci.yml`; README supported
  target table. Local Windows x64 run with Goose v2026.4 passed interpreter
  normal/debug and native build/run (`goose toolchain`: clang 14.0.6). Stale
  native-output and fail-propagation paths were exercised with a fake Goose.
  Hosted CI on PR #1 passed Goose lint, interpreter, and native tests on
  `ubuntu-24.04` (gcc) and `windows-2022` (MSVC via `msvc-dev-cmd` +
  `GOOSE_CC=msvc` in a Windows-only job). `scripts/test.py` treats toolchain
  launch/nonzero/unrecognized output as errors (not a successful skip) and
  aborts a native target when the prior executable cannot be removed;
  `scripts/test_selftest.py` covers those contracts.
- [x] Maintain behavioral tests for every public operation and failure status.
  Add a source-mapped coverage mechanism if Goose tooling permits it; report
  its actual scope and limitations instead of inferring a percentage.
  Evidence: `tests/api.goose` matrix for `header`, `frame`, `encode`,
  `publish`, `valid_utf8`, `valid_topic`, `valid_filter`, and `matches`,
  including zeroed outputs / unchanged buffers on failures where applicable.
  Goose v2026.4: no coverage/instrumentation command found in `goose help` or
  `goose help --man`; `tests/coverage.goose` is combinatorial behavior only.
  Not claimed: line/branch percentage; `encode` with `body.len > MAX_REMAINING`
  (impractical in-process allocation in this suite).
- [x] Add deterministic generated and malformed-input tests for lengths, flags,
  truncation, UTF-8 and wildcard boundaries. Establish a reproducible fuzzing
  or equivalent randomized-testing workflow with saved regressions. The initial
  reproducible run must execute at least 10,000 bounded cases with recorded seeds;
  this is a minimum smoke campaign, not a safety guarantee.
  Evidence: `tests/fuzz.goose` (saved regressions + deterministic generated
  cases + `std.rng` campaign); default seed `20261116` / `10000` cases recorded
  in README; wired into `scripts/test.py`. Local Windows run printed
  `Fuzz smoke passed: seed=20261116 cases=10000`. Limitations: bounded
  48-byte random inputs; not AFL/libFuzzer; not a memory-safety or
  conformance claim; interesting failures should be added to
  `saved_regressions`.
- [x] Record representative optimized-build baselines, including PUBLISH parsing,
  with inputs, commands, machine, toolchain, timing boundaries and at least
  seven repeated samples after warmup per workload.
  Evidence: `tests/bench_publish.goose` / `tests/benchmark.goose` /
  `scripts/bench.py`; Windows capture `baselines/m0-local-windows.md` (clang
  14.0.6, `clock_res_ns=100`); Linux capture `baselines/m0-local-linux.md`
  (Ubuntu 24.04 WSL2, Goose linux-x64 v2026.4, gcc 13.3.0, warmup 1 + 7
  samples, checksums `138498139` / `17675999524`, `clock_res_ns=9`). Measured
  source blobs share manifest
  `bb36a45d1c4cbcd568ffc1ec1bab1fc0bbedd8cf2d59d328b573a3eac3d42bcd`. Timing
  boundary: loop-only `clock()`. Limitations: short representative inputs; no
  network; not a CI SLA; Linux numbers are **WSL2**, not bare-metal GHA hosts.

**Exit:** automated normal and debug test runs pass; native builds pass on the
declared supported environments; every public API has positive, negative and
boundary cases; fuzz/randomized and benchmark workflows are reproducible and
their limitations recorded. Missing platforms or tooling remain explicit gaps.
**Reassessment (2026-11-17):** Exit criteria are **satisfied**. Native CI on
Linux+Windows at `58c7745` remains green; API/fuzz evidence unchanged; Windows
and Linux (WSL2 Ubuntu 24.04) optimized baselines are both recorded with source
identity and sample tables. Remaining gaps are optional (bare-metal Linux host
baselines, broader size sweeps, Goose coverage tooling)—not unmarked Exit
blockers.

### M1 — Complete PUBLISH codec (Exit met)

- [x] Add a PUBLISH encoder that validates topic, QoS flags and packet identifier,
  uses caller-provided non-overlapping buffers, and preserves output on failure.
  Evidence: `encode_publish` in `honkmqtt.goose`; `tests/publish_encode.goose`
  (independent wire vectors + sentinels); `tests/api.goose` status matrix;
  README contract (OASIS MQTT 3.1.1 §§1.5.3, 2.2.3, 2.3.1, 3.3, 4.7).
- [x] Specify buffer ownership, offsets, limits, failure precedence, incomplete
  input and compatibility with the existing parser and opaque encoder.
  Evidence: API comments + README; successful encodings round-trip through
  `publish`; opaque `encode` unchanged for non-PUBLISH framing.
- [x] Test QoS 0/1/2, DUP/RETAIN combinations, empty/binary payloads, topic and
  packet-id validity, buffer sizes, Remaining Length 127/128 transitions,
  adjacent trailing frames, truncation via parser, independent expected bytes
  before round trips. Evidence: `tests/publish_encode.goose`.
- [x] Maximum topic length encode vector (65535 accept / 65536 reject) and
  Remaining Length at `MAX_REMAINING` (accept) / `MAX_REMAINING+1` (reject),
  plus `NO_SPACE` for valid size with short `out`. Evidence:
  `tests/publish_encode.goose` (`topic_length_limits`, peak three buffers
  196617 bytes);
  opt-in `tests/publish_encode_maxrl.goose` (~512 MiB, two buffers; not in
  `scripts/test.py`). Commands and platform results:
  `baselines/m1-encode-limits.md`.
- [x] Optimized-build baseline for `encode_publish`: `tests/bench_encode_publish.goose`
  via `scripts/bench.py` (warmup + ≥7 checksum-validated samples);
  Windows and Ubuntu WSL2 captures in `baselines/m1-local-windows.md` and
  `baselines/m1-local-linux.md` (checksum `17860248136` on both; measurement
  commit `a38b0aa`).

**Exit:** the documented PUBLISH API and vectors pass on supported builds;
malformed inputs are bounded; performance has a reproducible baseline. No
QoS state-machine or broker interoperability claim follows from this milestone.
**M1 Exit criteria satisfied** by that evidence (still not a conformance or
security claim; main tip updates when this slice merges).

### M2 — MQTT 3.1.1 control-packet codec (in progress)

- [x] PUBACK/PUBREC/PUBREL/PUBCOMP parse and encode (fixed 4-byte Packet
  Identifier acknowledgements; OASIS MQTT 3.1.1 §§2.2.2–2.2.3, 2.3.1, 3.4–3.7).
  Evidence: `pubresp` / `encode_pubresp` and `PUBACK`/`PUBREC`/`PUBREL`/
  `PUBCOMP` constants in `honkmqtt.goose`; independent vectors and
  malformed/truncation/sentinel cases in `tests/pubresp.goose`; API matrix in
  `tests/api.goose`; README contract. No QoS exchange state.
- [ ] CONNECT/CONNACK
- [ ] SUBSCRIBE/SUBACK
- [ ] UNSUBSCRIBE/UNSUBACK
- [ ] PINGREQ/PINGRESP (typed helpers; opaque `encode`/`frame` already cover
  the 2-byte empty forms structurally)
- [ ] DISCONNECT
- For each remaining packet specify its fields and flags, mandatory lengths,
  identifier rules, list/string validation, malformed/truncated behavior, and
  limits from the relevant normative standard sections. Define
  direction/context-dependent checks separately from structural validation.
- Preserve compatibility of existing APIs or document and justify any breaking
  change. Do not present generic frame/encode as packet-body validation.

**Exit:** every MQTT 3.1.1 control-packet type has documented parse and encode
support, independent valid/invalid vectors and boundary tests. Track any
intentional protocol deviations, including non-minimal remaining lengths.
M2 remains **in progress** until the unchecked packet groups above are
evidenced.

### M3 — Integration and interoperability evidence

- Build a bounded transport adapter example that handles partial reads and
  writes without making the core own I/O; explicitly bound buffering.
- Test packet exchange with at least two independently implemented MQTT 3.1.1
  peers/brokers, including malformed input and reconnect scenarios where
  applicable. Record exact versions, setups, cases, and results.
- Run a repeatable fuzz/randomized campaign and assess failures, memory limits,
  denial-of-service behavior, and independent protocol vectors. Add regressions.
- Test end-to-end representative workloads; record throughput, latency,
  memory, runtime configuration and variability without universal speed claims.

**Exit:** reproducible interoperability and safety evidence covers the declared
codec behavior, with outstanding failures and untested requirements documented.
Passing selected tests is not certification or proof of complete safety.

### M4 — Stable codec release decision

- Review public API consistency, versioning and compatibility policy,
  documentation, error contracts, supported platforms, test evidence, and
  security reporting process. Resolve or clearly disclose material gaps.
- Decide whether the evidence supports a stable codec release; make the
  decision separately from implementation and document residual limitations.

**Exit:** a reviewed release decision and reproducible evidence; do not label
the library production-ready or conformant solely because this plan is complete.

### M5 — Future direction (not approved)

Choose separately whether to pursue MQTT 5 packet support, a client-side QoS
and session state machine, a broker, or other integrations. Each needs its own
scope, threat model, ownership, design, compatibility rules, tests and
performance plan before implementation. Network access and TLS belong outside
the current transport-independent codec unless that direction is explicitly
changed.

## Rules for each roadmap slice

1. Identify the milestone, exact behavior, applicable MQTT specification
   sections, API and error contracts, inputs, non-goals and acceptance tests.
2. Implement one bounded slice, preserving resource limits, safety checks,
   existing behavior and documented API ownership unless a change is explicit.
3. Add independent wire vectors and adverse-input tests; run the repository's
   normal, debug and native checks. Report missing runtimes or coverage honestly.
4. For performance-sensitive work measure complete equivalent operations,
   report raw repeated samples and correctness evidence, and retain checks.
5. Update documentation and milestone status only with concrete evidence.

Reference: [MQTT 3.1.1 OASIS standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).
