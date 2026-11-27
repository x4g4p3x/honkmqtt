# HonkMQTT roadmap

HonkMQTT is building a transport-independent MQTT 3.1.1 codec for Goose.
Applications supply the buffers, I/O, and scheduling. The
[`v0.1.0-alpha.1` preview](https://github.com/x4g4p3x/honkmqtt/releases/tag/v0.1.0-alpha.1)
provides structural parsing and encoding for all 14 control packet types,
plus topic validation and matching.

## Milestones

| Milestone | Status | Evidence |
| --- | --- | --- |
| M0 · Reliable foundation | Complete | [Test runner](scripts/test.py), [CI](.github/workflows/ci.yml), [API matrix](tests/api.goose), [seeded tests](tests/fuzz.goose), and [Windows](baselines/m0-local-windows.md) / [WSL2](baselines/m0-local-linux.md) baselines. Exit met at `cf8dbed`. |
| M1 · Complete PUBLISH codec | Complete | [Wire vectors](tests/publish_encode.goose), [maximum lengths](baselines/m1-encode-limits.md), and [Windows](baselines/m1-local-windows.md) / [WSL2](baselines/m1-local-linux.md) encode baselines. Exit met at `fc12ece`. |
| M2 · MQTT 3.1.1 control packets | Complete | [API reference](docs/api.md) and [packet test suites](docs/development.md#test-coverage). Exit met at `bb5e5d3`. |
| M3 · Transport and interoperability | Complete for the documented example workloads | [Stream regressions](examples/stream/REGRESSION.md), [broker interoperability](examples/tcp/INTEROP.md), and [loopback benchmark](baselines/m3-broker-loopback.md). |
| M4 · Stable codec release decision | Open | [Required evidence for `1.0.0`](#m4-stable-codec-release-decision) and [versioning transition](VERSIONING.md#release-phases). |
| M5 · Future direction | Deferred | [Scope choices](#m5-future-direction). |

## M3 evidence

The bounded adapter exercises short reads and writes, adjacent frames,
backpressure, and clean or truncated EOF. Seeded checks replay 128 I/O
schedules and 64 varied packet streams. A Linux test checks the bridge's IPC
size limit, socket read cap, and child deadline and cleanup.

All six recorded loopback interoperability cases passed on Mosquitto 2.0.18
and Aedes 0.51.3. The combined codec, adapter, and benchmark passed all 13
Goose test programs in normal, debug, and native modes on Windows and Ubuntu
under WSL2. Each full benchmark run verifies 28,000 QoS 0 echoes across both
brokers and the 16-byte and 192-byte workloads. The evidence covers those
example configurations. Broader traffic mixes, multiple clients, and
production resource behavior remain open.

## M4 stable codec release decision

`1.0.0` means the codec is ready for production use within its documented
scope. That scope covers MQTT 3.1.1 packet handling in a caller-owned
transport. The application still owns I/O, authentication, QoS exchanges,
and session state. The project stays on `0.x` while any gate below is open.

### Define the production scope before testing

Name the downstream use case and document the Goose versions, platforms,
and broker configurations it relies on. Set the packet and buffer limits,
traffic mix, concurrent stream count, and expected steady and peak loads.
Set measurable pass/fail budgets for throughput, tail latency, memory, and
recovery under backpressure or disconnects. Review these limits before the
release runs. The release claim covers the scope supported by the results.

### Evidence required on the release candidate

- [ ] **Stable public contract.** Review the [public API](VERSIONING.md#public-api)
  and publish the supported environments, packet behavior, operating
  limits, and buffer guarantees. Record migration steps for any preview
  behavior that changes. Commit to preserving the documented API across
  `1.x`.
- [ ] **Wire correctness.** Review a test matrix against the MQTT 3.1.1
  specification for all 14 packet types. Run independent wire vectors for
  parsing and encoding, including valid, invalid, truncated, and boundary
  inputs where applicable. Record each intentional wire deviation and its
  effect on the supported use case. Resolve discrepancies that would
  invalidate the published contract.
- [ ] **Malformed input and resource bounds.** Run a reproducible campaign
  of at least 1,000,000 generated cases across all packet families.
  Report valid and invalid cases and the size and fragmentation boundaries
  exercised. Record commands and seeds, and test the documented size limits
  directly. Require the expected results, buffer contents, and consumed
  counts, with zero crashes or hangs. Save regressions for discovered
  defects.
- [ ] **Broker interoperability.** Repeatable tests against two independently
  implemented brokers must exercise connection, subscribe and unsubscribe,
  QoS 0 delivery, the QoS 1 and 2 publish and acknowledgement exchanges, and
  reconnect. The test driver owns session behavior. Record broker versions,
  cases, results, and which parts of the codec each case validates.
- [ ] **Downstream use under load.** Run a downstream Goose application
  outside the example harness in production or a representative staging
  environment. Use the pinned candidate, the application's normal
  transport path, and caller-owned buffers. Run for at least one hour at
  the defined steady load, exercise peak traffic and backpressure, and
  check recovery after disconnects. Verify packet results throughout,
  meet the agreed budgets, and demonstrate bounded memory across repeated
  connections. Record the workload, hardware, and measured results.
- [ ] **Release verification.** On the exact candidate commit, pass lint and
  normal, debug, and native tests on each supported CI target. A separate
  Goose project must fetch the pinned candidate and use the documented API
  with caller-owned buffers. Publish reproducible install and integration
  instructions for the supported scope.
- [ ] **Maintenance and sign-off.** Provide a tested private reporting
  channel and name the maintainer responsible for triage. Resolve known
  security blockers and defects that could cause crashes, incorrect handling
  of supported packets, resource-limit violations, or documented
  compatibility failures.

### Record the release decision

Attach a pass or fail result and its evidence to each gate. Record the exact
candidate commit, toolchains, commands, and inputs. Include test logs and
measured results against the agreed limits. An independent reviewer must
reproduce the downstream result, rerun a representative set of the
correctness and resource checks, and sign off on the documented scope.

The existing M3 results support the preview. Revalidate any reused checks on
the candidate. Any failed or unevidenced gate keeps the release on `0.x`.

## M5 future direction

MQTT 5, client-side QoS and session handling, a broker, TLS, and persistence
are separate product decisions. Each needs its own scope, tests, and support
commitments before implementation.

See the [development guide](docs/development.md) for verification commands
and the [MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html)
for protocol requirements.
