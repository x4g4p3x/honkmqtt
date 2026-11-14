---
name: honkmqtt-performance
description: Measure and improve HonkMQTT throughput, latency, or resource use while preserving protocol behavior and safety. Use for HonkMQTT performance investigations and optimizations, not unrelated Goose projects.
---

# Tune HonkMQTT performance

1. Inspect Git state, `AGENTS.md`, `README.md`, `ROADMAP.md`, relevant APIs,
   tests and benchmarks; preserve unrelated changes and analysis-only scope.
   Choose representative complete operations and adverse/adjacent workloads,
   with explicit metrics, inputs, timing boundaries and acceptance criteria.
   The existing `tests/benchmark.goose` is a narrow combined workload, not a
   general throughput or PUBLISH benchmark.
2. Before edits, capture source and dirty state, hardware, OS, toolchain,
   build options, input sizes, commands, warmup and repeated raw samples.
   Measure optimized native builds, distinguish startup, preparation, steady
   state, memory and I/O, and profile separately if instrumentation affects
   timings. Missing tools and noisy or failed runs remain visible.
3. Identify the measured bottleneck and propose a mechanism. Preserve status
   codes, wire bytes, bounds, input validation, buffer ownership, non-overlap
   requirements and incomplete-frame behavior. Never remove work or relax
   safety checks to earn a speedup. Add independent correctness and adverse
   input tests for changed paths, including cache validity and concurrency if
   relevant.
4. Compare equivalent complete before/after operations on the same machine,
   inputs, build and resource limits. Serialize runs; warm up, retain repeated
   samples and alternate order or repeat sessions when drift matters. Report
   absolute units, sample count, spread, tradeoffs and workload scope. A faster
   microbenchmark alone is not evidence of faster application throughput.
5. Check whether the bottleneck moved and assess adjacent workloads. Revert
   speculative changes without reliable benefit; keep relevant regression
   tests. Run the normal, debug and native checks from `AGENTS.md`, review the
   diff, and document evidence and limitations. Do not put wall-clock
   assertions in unit tests or claim security/conformance from performance.

Do not publish benchmarks, push, or release without authorization.
