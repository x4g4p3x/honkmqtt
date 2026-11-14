# HonkMQTT development

HonkMQTT is an experimental, transport-independent MQTT 3.1.1 framing and
topic-filter library written in Goose. `honkmqtt.goose` contains the library;
`tests/test.goose` and `examples/basic.goose` exercise its public API. Read
the README for its explicit scope and limitations before changing behavior.

## Verification

- Use Goose v2026.4 or newer. Run `goose tests/test.goose` and
  `goose tests/publish.goose`, including each with `--debug`; build and run
  both tests natively when a supported C compiler is available.
- Test malformed and truncated input, boundary lengths, unchanged output on
  errors, and topic/UTF-8 edge cases when touching the relevant code. Incomplete
  frames must consume zero bytes. Do not claim validation of other packet bodies,
  MQTT conformance, or production security without appropriate evidence.
- Preserve caller-owned buffers, documented non-overlap requirements, bounds,
  error behavior, and transport independence. Treat all input as untrusted.
- For performance changes, measure representative complete operations before and
  after using equivalent optimized builds and repeated samples. Preserve safety
  checks and correctness; report the workload, variability, and limitations.
  Do not add timing assertions to ordinary tests.
- Do not commit generated executables or build artifacts. Keep public API and
  README examples consistent with intentional behavioral changes.
