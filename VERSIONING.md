# Versioning and compatibility

HonkMQTT follows [Semantic Versioning 2.0.0](https://semver.org/). A version
such as `0.1.0-alpha.1` has the Git tag `v0.1.0-alpha.1`. The `v` prefix is
the tag convention. Goose consumers can pin that exact tag in their import.

## Release phases

HonkMQTT currently uses the **`0.x` preview policy**. During this phase, the
public API can evolve and a minor version can carry a breaking change.
Preview users should pin an exact tag and review the release notes before
upgrading.

`1.0.0` means the codec is ready for production use within its documented
scope. Publish it only after all required M4 gates pass on the release
candidate and an independent reviewer signs off on the evidence. Publish
the supported environments and operating limits with the release. The
project uses `0.x` while any gate is open.
[M4 release criteria](ROADMAP.md#m4-stable-codec-release-decision)

The first stable release establishes the API we will preserve across `1.x`.
The stable version-bump rules take effect with that release. Both phases
use SemVer 2.0.0.

## Public API

The package entry is `honkmqtt.goose` and the public namespace is
`honkmqtt::`. The functions and constants below are the versioned API.
Their contracts cover signatures and return fields, constant values,
documented wire behavior, status and failure precedence, consumed and written
byte counts, and buffer ownership, overlap, and lifetime rules. See the
[codec API reference](docs/api.md) for details.

| Area | Functions |
| --- | --- |
| Framing | `header`, `frame`, `encode` |
| Topics | `valid_utf8`, `valid_topic`, `valid_filter`, `matches` |
| Publish | `publish`, `encode_publish`, `pubresp`, `encode_pubresp` |
| Connection | `connect`, `encode_connect`, `connack`, `encode_connack`, `disconnect`, `encode_disconnect` |
| Subscriptions | `subscribe`, `subscribe_next`, `encode_subscribe`, `suback`, `encode_suback`, `unsubscribe`, `unsubscribe_next`, `encode_unsubscribe`, `unsuback`, `encode_unsuback` |
| Keep alive | `pingreq`, `encode_pingreq`, `pingresp`, `encode_pingresp` |

| Area | Constants |
| --- | --- |
| Framing | `OK`, `INCOMPLETE`, `INVALID`, `NO_SPACE`, `MAX_REMAINING` |
| Publish | `PUBACK`, `PUBREC`, `PUBREL`, `PUBCOMP` |
| Connection | `CONNECT_PROTOCOL_LEVEL`, `CONNECT_MIN_REMAINING`, `CONNECT_MAX_REMAINING`, `CONNACK_ACCEPTED`, `CONNACK_REFUSED_PROTOCOL`, `CONNACK_REFUSED_IDENTIFIER`, `CONNACK_REFUSED_CREDENTIALS`, `CONNACK_REFUSED_SERVER`, `CONNACK_REFUSED_UNAUTHORIZED`, `DISCONNECT` |
| Subscriptions | `SUBSCRIBE_MIN_REMAINING`, `SUBACK_MIN_REMAINING`, `UNSUBSCRIBE_MIN_REMAINING`, `SUBACK_QOS0`, `SUBACK_QOS1`, `SUBACK_QOS2`, `SUBACK_FAILURE` |
| Keep alive | `PINGREQ`, `PINGRESP` |

Internal helpers, module layout, direct imports of implementation files,
examples, and benchmark tools may change independently of the public API.

## Preview version bumps

For normal `0.y.z` releases, bump the minor version and reset the patch to
zero for new public functionality, deprecations, or incompatible public
changes. Use a patch release for compatible fixes. Put breaking changes
under a **Breaking changes** heading in the release notes and describe any
migration steps.

## Stable version bumps

Apply these rules from `1.0.0`.

| Bump | When to use it |
| --- | --- |
| **MAJOR** | An incompatible change to the public API or a supported environment. Examples include changing return fields, rejecting an input the contract accepted, or dropping a supported Goose version. Reset minor and patch to zero. |
| **MINOR** | A compatible public addition or a public API deprecation. Keep deprecated APIs available through the current major version. Reset patch to zero. |
| **PATCH** | A compatible fix that restores documented behavior. For example, return zero bytes consumed on an incomplete frame as promised. |

Choose the strongest bump required by the changes in the release.

## Pre-release tags

A suffix such as `-alpha.1`, `-beta.1`, or `-rc.1` identifies a preview of the
named target version and sorts before it. Increment the numeric suffix for
subsequent builds in the same stage. For example,
`0.1.0-alpha.1 < 0.1.0-alpha.2 < 0.1.0`. Document changes between preview
builds in the release notes.

## Publishing

Tag the exact tested commit on `main` after its supported CI targets pass.
Verify that a separate Goose consumer can fetch and use the tagged package.
Mark tags with pre-release suffixes as pre-releases on GitHub. Release notes
state the version, supported toolchain and platforms, API changes, and
relevant limitations.
Published tags and release contents are immutable. Ship corrections in a new
version.
