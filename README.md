# HonkMQTT

**MQTT speaks Goose.**

HonkMQTT is an experimental, transport-independent MQTT 3.1.1 framing and topic-filter library written in Goose. It has no C source or third-party library dependencies. Goose's native executable toolchain itself uses C; this is not a claim that generated executables or the Goose runtime contain no C.

## Status

This is an early foundation, **not a complete MQTT client or a complete MQTT 3.1.1 implementation**. It provides:

- Fixed-header parsing with bounded MQTT remaining lengths, flag checks, and incremental frame detection. Incomplete frames consume no bytes.
- Encoding an opaque body into a caller-provided buffer.
- UTF-8 and topic name/filter checks, including wildcard matching and the `$` topic rule.

It does **not** parse or validate packet bodies, produce packet-specific structures, validate CONNECT or PUBLISH fields, implement QoS/session state, perform network I/O, support MQTT 5 properties, or claim protocol conformance. It rejects non-minimal remaining-length encodings. Applications must validate packet bodies before acting on untrusted data. The UTF-8 checks enforce well-formed Unicode scalar values and exclude U+0000; they do not reject additional code points discouraged by MQTT. Do not use this as a security boundary or production MQTT implementation yet.

The fixed-header and frame functions accept `const u8[:]` and return status codes; `frame` reports how many bytes to consume only on success. Keep incomplete input in your own bounded buffer and retry after receiving more data. Supply a maximum permitted body size to `frame` to limit buffering. `encode` requires a non-overlapping output buffer. The library never owns the transport.

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
goose tests/test.goose
goose build tests/test.goose
```

Goose's in-process runner needs no separate C compiler on Windows. Native `goose build` needs a supported C compiler. The tests are deterministic software checks, not an interoperability or conformance suite. The protocol reference is the [OASIS MQTT 3.1.1 standard](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

## Roadmap

Packet-specific parsers and encoders, complete validation, broader boundary and interoperability testing, and MQTT 5 are future work. Contributions are welcome.

MIT licensed; see [LICENSE](LICENSE).
