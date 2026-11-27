# Codec API

Import the package through `honkmqtt.goose` and call functions in the
`honkmqtt::` namespace. The [versioning policy](../VERSIONING.md#public-api)
lists the public functions and constants. Packet rules refer to
[OASIS MQTT 3.1.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).

## Status and buffer contracts

Byte inputs use `const u8[:]` and output buffers use `u8[:]`. Status codes,
offsets, lengths, and packet identifiers use `i64`. The first header byte
passed to `encode` uses `u8`.

| Status | Meaning |
| --- | --- |
| `OK` (0) | The requested operation succeeded. |
| `INCOMPLETE` (1) | The operation needs more input bytes. Retain the buffered prefix and retry. |
| `INVALID` (2) | An argument, wire field, or configured limit failed validation. |
| `NO_SPACE` (3) | The encoder needs a larger output buffer. |

- Packet parsers consume one packet at a time. The consumed count includes
  the fixed header and body. Trailing bytes belong to the caller.
- Failed parsers return zero counts, offsets, and numeric fields. Boolean
  fields are false. Incomplete input always consumes zero bytes.
- Parser offsets are relative to the input slice passed to that call. Keep the
  backing bytes available and unchanged while you use those offsets or views.
- Encoders return `(status, bytes_written)`. They validate and size the packet
  before writing and leave `out` unchanged on every failure. A failure reports
  zero bytes written. Each borrowed input slice must be disjoint from `out`.
- `max_body` limits the MQTT Remaining Length, which excludes the fixed
  header. A negative limit returns `INVALID`. The protocol maximum is
  `MAX_REMAINING` (268,435,455 bytes). Choose a limit that fits your application
  and [receive buffer](transport.md#size-the-buffers).

The codec checks packet structure. The application interprets payloads,
matches request and response packets, and implements session, QoS,
authentication, and Keep Alive behavior.

## Framing

| Function | Success result | Operation |
| --- | --- | --- |
| `header(input)` | `(OK, header_length, body_length)` | Reads the fixed header and Remaining Length. The body can still be absent. |
| `frame(input, max_body)` | `(OK, consumed)` | Finds the end of the first complete frame and applies the body-size limit. |
| `encode(first, body, out)` | `(OK, bytes_written)` | Writes the first header byte, a minimal Remaining Length, and the opaque body. |

`header` checks the packet-type code, fixed-header flags, and the Remaining
Length encoding. HonkMQTT rejects non-minimal Remaining Length encodings.
An invalid first byte can fail before the rest of the header arrives.

`frame` checks the body limit argument, then propagates the header status.
Once the header is complete, a body above the limit returns `INVALID` even
if it has yet to arrive. A permitted body with missing bytes returns
`INCOMPLETE`. Use the corresponding packet parser to check the body.

`encode` rejects a body above `MAX_REMAINING` or an invalid first byte before
checking the output capacity. It treats the body bytes as opaque.

## UTF-8 and topics

| Function | Returns true when |
| --- | --- |
| `valid_utf8(text)` | The bytes encode Unicode scalar values and exclude U+0000. An empty string is allowed. |
| `valid_topic(topic)` | The name has 1–65,535 valid UTF-8 bytes and contains neither `+` nor `#`. |
| `valid_filter(filter)` | The filter has 1–65,535 valid UTF-8 bytes. Each `+` occupies an entire level. A `#` occupies the final level. |
| `matches(filter, topic)` | Both inputs validate and the topic matches the filter. |

A leading `+` or `#` does not match a topic whose first byte is `$`.
For example, `sensors/+` matches `sensors/kitchen`, and `sensors/#` matches
both `sensors` and `sensors/kitchen`. `#` does not match `$SYS/uptime`.
The UTF-8 check accepts additional code points that MQTT discourages.

## PUBLISH

`publish(input, max_body)` returns
`(status, consumed, topic_offset, topic_length, payload_offset, packet_identifier)`.
The topic is `input[topic_offset..topic_offset + topic_length]` and the payload
is `input[payload_offset..consumed]`. QoS 0 returns Packet Identifier zero.
QoS 1 and 2 require a nonzero identifier on the wire. An empty payload is valid.

Validation proceeds in this order.

1. Check the limit argument, fixed header, packet type, and declared body size.
2. Return `INCOMPLETE` if the declared body has missing bytes.
3. Check the length-prefixed topic name and the Packet Identifier required by
   the QoS flags. Reject a field that runs past the packet boundary.

`encode_publish(dup, qos, retain, topic, packet_id, payload, out)` takes QoS
0–2 and a valid topic name. Use `dup=false` and `packet_id=0` for QoS 0.
Supply an identifier from 1 through 65,535 for QoS 1 or 2. Invalid flags,
topic, identifier, or Remaining Length take precedence over a short output
buffer.

### PUBLISH example

Save this as `main.goose` and run `goose run main.goose`. It encodes a QoS 0
PUBLISH into a 64-byte buffer, then checks the topic and reads the payload
from that same buffer.

```goose
import honkmqtt from "x4g4p3x/honkmqtt@v0.1.0-alpha.1";

fn main() {
    var packet: u8[64] = [0; 64];
    let write_status, written = honkmqtt::encode_publish(
        false, 0, false, "sensors/kitchen", 0, "22", packet);
    assert(write_status == honkmqtt::OK);

    let encoded = packet[0..written];
    let read_status, consumed, topic_off, topic_len, payload_off, packet_id =
        honkmqtt::publish(encoded, 62);
    assert(read_status == honkmqtt::OK && consumed == written && packet_id == 0);

    let topic = encoded[topic_off..topic_off + topic_len];
    let payload = encoded[payload_off..consumed];
    assert(honkmqtt::matches("sensors/+", topic));
    assert(payload.len == 2 && payload[0] == '2' && payload[1] == '2');
    print("Decoded ", payload.len, " payload bytes");
}
```

The example prints `Decoded 2 payload bytes`.

For a local checkout, run `goose run examples/basic.goose` from the repository
root to exercise the packet families.

## Publish acknowledgements

`pubresp(input, kind)` handles `PUBACK`, `PUBREC`, `PUBREL`, and `PUBCOMP`.
Success returns `(OK, 4, packet_identifier)`. Each has Remaining Length 2
and a nonzero big-endian Packet Identifier. PUBREL uses fixed flags
`0b0010`.

The parser rejects an unsupported `kind` before reading input. It then
propagates the header status and checks the packet type and Remaining Length.
A missing body yields `INCOMPLETE` only after those checks pass. A complete
body with identifier zero yields `INVALID`.

`encode_pubresp(kind, packet_id, out)` validates the kind and identifier
before checking for four output bytes.

## Connection packets

### CONNECT

`connect(input, max_body)` returns the following fields in order.

```text
status, consumed, connect_flags, keep_alive,
client_id_off, client_id_len,
will_topic_off, will_topic_len,
will_message_off, will_message_len,
username_off, username_len,
password_off, password_len
```

Absent optional fields use offset and length zero. A present but empty field
has length zero and an offset immediately after its two-byte length prefix.

The parser requires protocol name `MQTT` and level `CONNECT_PROTOCOL_LEVEL`
(4). It checks the reserved flag, Will flags and fields, the User Name and
Password presence flags, and exact body consumption. Client ID and User Name
use MQTT UTF-8. Will Topic must be a valid topic name. Will Message and
Password are opaque byte strings. An empty Client ID requires Clean Session.
The application applies its broker's additional Client ID policy.

After the body limit argument and header status, the parser checks the
packet type, body cap, and structural Remaining Length range of 12–327,695
bytes (`CONNECT_MIN_REMAINING` through `CONNECT_MAX_REMAINING`). Missing body
bytes return `INCOMPLETE` after those checks and before field validation.

The encoder takes these arguments.

```text
encode_connect(clean_session, keep_alive, client_id,
               will, will_qos, will_retain, will_topic, will_message,
               user, username, pass, password, out)
```

Pass a Keep Alive value from 0 through 65,535 seconds. When `will` is false, set
`will_qos=0` and `will_retain=false`. The Will slices are then ignored.
With a Will, use QoS 0–2. The `user` and `pass` flags govern their slices,
and `pass` requires `user`. Each supplied length-prefixed field fits in
65,535 bytes. A present User Name, Password, or Will Message can be empty.
Field validation takes precedence over output capacity.

### CONNACK

`connack(input)` returns `(status, consumed, session_present, return_code)`.
Success consumes four bytes. The fixed header begins with `0x20` and declares
Remaining Length 2. The only permitted acknowledge flag is Session Present.
Return codes range from 0 through 5, from `CONNACK_ACCEPTED` to
`CONNACK_REFUSED_UNAUTHORIZED`. Session Present requires code 0.

Validation proceeds from header status to type and Remaining Length, then
body availability, then flags and return code. An invalid type or length
takes precedence over missing body bytes.
`encode_connack(session_present, return_code, out)` validates the flag and
code before checking capacity for four bytes.

## Subscription packets

| Parser | Successful tuple | Payload |
| --- | --- | --- |
| `subscribe(input, max_body)` | `(OK, consumed, packet_id, list_off, list_len)` | One or more length-prefixed topic filters, each followed by a requested QoS byte from 0 through 2. |
| `suback(input, max_body)` | `(OK, consumed, packet_id, codes_off, codes_len)` | One or more return-code bytes `0x00`, `0x01`, `0x02`, or `0x80`. |
| `unsubscribe(input, max_body)` | `(OK, consumed, packet_id, list_off, list_len)` | One or more length-prefixed topic filters without QoS bytes. |

The declared Remaining Length minimums are 6, 3, and 5 bytes respectively
(`SUBSCRIBE_MIN_REMAINING`, `SUBACK_MIN_REMAINING`, and
`UNSUBSCRIBE_MIN_REMAINING`). The first bytes are `0x82`, `0x90`, and
`0xA2`. Each parser checks the limit argument, then the header, type, body
cap, and minimum length before body availability. A complete body must
contain a nonzero Packet Identifier and a valid payload that fits within the
frame. Repeated filters are allowed.

Use `subscribe_next(input, pos, end)` or `unsubscribe_next(input, pos, end)`
with the original input slice. Start at `list_off` and set
`end = list_off + list_len`. Stop when `pos == end`.

- `subscribe_next` returns `(OK, next_pos, filter_off, filter_len, qos)`.
- `unsubscribe_next` returns `(OK, next_pos, filter_off, filter_len)`.

Advance to `next_pos` on success. Both iterators return `INVALID` for an
invalid interval, an entry that extends beyond `end`, or a malformed field.
Calling the iterator at `end` yields `INVALID`.

`encode_subscribe(packet_id, list, out)` and
`encode_unsubscribe(packet_id, list, out)` take pre-encoded payload lists.
Each filter starts with a two-byte big-endian length followed by its bytes.
A SUBSCRIBE entry ends with its QoS byte. For example,
`00 01 61 00` encodes filter `a` at QoS 0, and `00 01 61` encodes the
UNSUBSCRIBE entry for `a`.

`encode_suback(packet_id, codes, out)` takes pre-encoded return-code bytes.
The constants are `SUBACK_QOS0`, `SUBACK_QOS1`, `SUBACK_QOS2`, and
`SUBACK_FAILURE`. These three encoders validate the Packet Identifier, reject
payloads above `MAX_REMAINING - 2` before walking entries or codes, and validate
the payload before checking capacity.

`unsuback(input)` returns `(OK, 4, packet_identifier)` on success. It
requires `0xB0`, Remaining Length 2, and a nonzero Packet Identifier.
The type or declared length can fail before the body arrives. Otherwise an
absent body returns `INCOMPLETE` and a zero identifier returns `INVALID`.
`encode_unsuback(packet_id, out)` validates the identifier before checking for
four output bytes.

## Empty control packets

| Parser | Encoder | Exact bytes |
| --- | --- | --- |
| `pingreq(input)` | `encode_pingreq(out)` | `C0 00` |
| `pingresp(input)` | `encode_pingresp(out)` | `D0 00` |
| `disconnect(input)` | `encode_disconnect(out)` | `E0 00` |

The parsers return `(OK, 2)` on success. They propagate header status first,
then reject a wrong type or nonzero declared Remaining Length. Each encoder
returns `NO_SPACE` if `out` is shorter than two bytes.
