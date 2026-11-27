# HonkMQTT development

HonkMQTT is an experimental, transport-independent MQTT 3.1.1 framing and
topic-filter library written in Goose. `honkmqtt.goose` is the package entry;
`wire.goose`, `topics.goose`, `publish.goose`, `connect.goose`,
`subscriptions.goose`, and `control.goose` are implementation modules.
`tests/test.goose` and `examples/basic.goose` exercise its public API. Read
the README and `ROADMAP.md` for scope, limitations and milestone criteria.
Project-specific Codex workflows are in `.agents/skills/`.

## Verification

- Run `python scripts/lint.py` with Goose on PATH (or set `GOOSE` to its
  executable). It checks Goose formatting and fails on compiler diagnostics.
- Use Goose v2026.4 or newer. Prefer the single entry point
  `python scripts/test.py` (normal and `--debug` interpreter runs for
  `tests/test.goose`, `tests/publish.goose`, `tests/publish_encode.goose`,
  `tests/pubresp.goose`, `tests/connack.goose`, `tests/connect.goose`,
  `tests/subscribe.goose`, `tests/unsubscribe.goose`,
  `tests/empty_control.goose`, `tests/transport.goose`, `tests/coverage.goose`,
  `tests/api.goose`, and `tests/fuzz.goose`). Add `--native` to build and run
  those programs when `goose toolchain` reports a C compiler, and
  `--require-native` when native success is mandatory. Run
  `python scripts/test_selftest.py` after changing the entry point.
  Individual `goose tests/...` commands remain valid. Do not invent a Goose
  source-coverage percentage; v2026.4 has no such tool. For fuzz changes, keep
  the default seed/case count reproducible and save fixed regressions.
- Test malformed and truncated input, boundary lengths, unchanged output on
  errors, and topic/UTF-8 edge cases when touching the relevant code. Incomplete
  frames must consume zero bytes. Do not claim validation of other packet bodies,
  MQTT conformance, or production security without appropriate evidence.
- Preserve caller-owned buffers, documented non-overlap requirements, bounds,
  error behavior, and transport independence. Treat all input as untrusted.
- For performance changes, measure representative complete operations before and
  after using equivalent optimized builds and repeated samples. Prefer
  `python scripts/bench.py` (warmup + ≥7 serialized samples, checksum checks).
  Preserve safety checks and correctness; report the workload, variability, and
  limitations. Do not add timing assertions to ordinary tests.
- Do not commit generated executables or build artifacts. Keep public API and
  README examples consistent with intentional behavioral changes.
