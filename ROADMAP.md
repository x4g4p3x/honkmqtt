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

As of the test-entry / CI slice on top of `919f6ed`, the library has
fixed-header parsing, bounded frame detection, opaque-body encoding, PUBLISH
parsing, UTF-8/topic validation, and topic-filter matching. `scripts/test.py`
is the repeatable local test entry point; `.github/workflows/ci.yml` pins Goose
v2026.4 and runs lint plus interpreter and native tests on `ubuntu-24.04` and
`windows-2022` (x64). The deterministic tests cover selected boundaries; there
is no measured Goose source-coverage percentage, fuzz campaign, broker
interoperability result, or MQTT conformance certification. The PUBLISH
parser does not implement QoS or session state. The existing benchmark covers
one narrow combined framing/matching workload, not the complete library.

## Milestones

### M0 — Reliable foundation (in progress)

- [x] Provide a single repeatable test entry point and CI initially targeting
  Windows x64 and Linux x64 with Goose v2026.4 pinned; document C compiler
  versions and supported versions. Add other targets only with test evidence.
  Evidence: `scripts/test.py`; `.github/workflows/ci.yml`; README supported
  target table. Local Windows x64 run with Goose v2026.4 passed interpreter
  normal/debug and native build/run (`goose toolchain`: clang 14.0.6). Remote
  GitHub Actions evidence is pending until this workflow is pushed; Windows CI
  native expects MSVC via `msvc-dev-cmd`.
- Maintain behavioral tests for every public operation and failure status.
  Add a source-mapped coverage mechanism if Goose tooling permits it; report
  its actual scope and limitations instead of inferring a percentage.
- Add deterministic generated and malformed-input tests for lengths, flags,
  truncation, UTF-8 and wildcard boundaries. Establish a reproducible fuzzing
  or equivalent randomized-testing workflow with saved regressions. The initial
  reproducible run must execute at least 10,000 bounded cases with recorded seeds;
  this is a minimum smoke campaign, not a safety guarantee.
- Record representative optimized-build baselines, including PUBLISH parsing,
  with inputs, commands, machine, toolchain, timing boundaries and at least
  seven repeated samples after warmup per workload.

**Exit:** automated normal and debug test runs pass; native builds pass on the
declared supported environments; every public API has positive, negative and
boundary cases; fuzz/randomized and benchmark workflows are reproducible and
their limitations recorded. Missing platforms or tooling remain explicit gaps.

### M1 — Complete PUBLISH codec

- Add a PUBLISH encoder that validates topic, QoS flags and packet identifier,
  uses caller-provided non-overlapping buffers, and preserves output on failure.
- Specify buffer ownership, offsets, limits, failure precedence, incomplete
  input and compatibility with the existing parser and opaque encoder.
- Test QoS 0/1/2, DUP/RETAIN combinations, empty/binary payloads, maximum topic
  length, malformed strings and IDs, buffer sizes, length-field transitions,
  concatenated and truncated frames. Compare against independent expected
  wire vectors and exercise encode/decode round trips.

**Exit:** the documented PUBLISH API and vectors pass on supported builds;
malformed inputs are bounded; performance has a reproducible baseline. No
QoS state-machine or broker interoperability claim follows from this milestone.

### M2 — MQTT 3.1.1 control-packet codec

- Implement and test bounded, packet-specific parsing and encoding in slices:
  CONNECT/CONNACK; PUBACK/PUBREC/PUBREL/PUBCOMP; SUBSCRIBE/SUBACK;
  UNSUBSCRIBE/UNSUBACK; PINGREQ/PINGRESP; DISCONNECT.
- For each packet specify its fields and flags, mandatory lengths, identifier
  rules, list/string validation, malformed/truncated behavior, and limits from
  the relevant normative standard sections. Define direction/context-dependent
  checks separately from structural validation.
- Preserve compatibility of existing APIs or document and justify any breaking
  change. Do not present generic frame/encode as packet-body validation.

**Exit:** every MQTT 3.1.1 control-packet type has documented parse and encode
support, independent valid/invalid vectors and boundary tests. Track any
intentional protocol deviations, including non-minimal remaining lengths.

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
