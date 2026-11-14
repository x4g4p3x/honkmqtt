---
name: honkmqtt-feature
description: Implement a bounded HonkMQTT roadmap feature or protocol capability with wire-level evidence, safe buffer contracts, and validated documentation. Use for HonkMQTT implementation, not general Goose work or performance-only investigations.
---

# Implement a HonkMQTT roadmap slice

1. Inspect Git state, `AGENTS.md`, `README.md`, `ROADMAP.md`, relevant code and
   tests. Preserve unrelated changes. Identify the requested milestone and a
   deliverable slice; if the request is analysis-only, do not implement it.
2. Consult the relevant normative MQTT version and packet sections. State the
   supported behavior, non-goals, API and compatibility, ownership, limits,
   malformed/truncated handling, output-on-failure, and acceptance tests before
   coding. Do not assume session state, transport, MQTT 5, or full conformance
   is in scope. Resolve material product decisions with the user when needed.
3. Implement the slice using bounded operations and caller-owned buffers; retain
   framing limits, no-consumption-on-incomplete, documented overlap rules and
   status behavior. Validate untrusted lengths and fields before indexing or
   slicing. Preserve safety checks and supported inputs.
4. Add independent specification-derived valid and invalid wire vectors and
   regression tests for boundaries, truncation, malformed fields, adjacent
   frames and failure paths as relevant. Round trips supplement, not replace,
   independent expected bytes. Check outputs and untouched buffers on failure.
5. Run the normal, debug and native tests in `AGENTS.md`, plus feature-specific
   tests and examples. Record skipped checks and actual coverage; do not infer
   protocol conformance, security or a coverage percentage from passing tests.
   Document the API, limitations and evidence, and update roadmap status only
   when its stated exit criteria are met. Review the diff and report results.

For performance-sensitive changes, establish and compare representative complete
workloads as described by the `honkmqtt-performance` skill. Do not broaden a
feature request into a release, push, or external publication without authority.
