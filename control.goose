namespace honkmqtt;
import .wire;

// MQTT 3.1.1 QoS acknowledgement control packet types (OASIS §§3.4–3.7).
const PUBACK = 4;
const PUBREC = 5;
const PUBREL = 6;
const PUBCOMP = 7;

fn pubresp_flags(kind: i64) -> i64 {
    if kind == PUBREL { return 2; }
    return 0;
}

fn valid_pubresp_kind(kind: i64) -> bool {
    return kind == PUBACK || kind == PUBREC || kind == PUBREL || kind == PUBCOMP;
}

// Parse one MQTT 3.1.1 PUBACK, PUBREC, PUBREL, or PUBCOMP (OASIS MQTT 3.1.1
// §§2.2.2–2.2.3, 2.3.1, 3.4–3.7). Each is exactly four bytes on the wire when
// Remaining Length is encoded minimally: type/flags, 0x02, Packet Identifier
// MSB, LSB. There is no payload. `kind` must be PUBACK/PUBREC/PUBREL/PUBCOMP
// and must match the packet type byte. On success returns (OK, 4, packet_id).
// On any error consumed and packet_id are zero; trailing bytes stay unconsumed.
//
// Failure precedence (first match wins; consumed and packet_id are always 0):
//   INVALID — kind not in {4,5,6,7}
//   (else) propagate header() status (INCOMPLETE/INVALID for truncated or
//          illegal fixed-header/flags/non-minimal Remaining Length)
//   INVALID — packet type ≠ kind; or Remaining Length ≠ 2 (even if the body
//             bytes have not arrived yet, once the header is complete)
//   INCOMPLETE — header OK and RL==2 but identifier bytes are missing
//   INVALID — Packet Identifier == 0
fn pubresp(input: const u8[:], kind: i64) -> i64, i64, i64 {
    if !valid_pubresp_kind(kind) { return INVALID, 0, 0; }
    let status, prefix, body = header(input);
    if status != OK { return status, 0, 0; }
    if input[0] / 16 != kind || body != 2 { return INVALID, 0, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0, 0; }
    let id = (input[prefix] as i64) * 256 + input[prefix + 1];
    if id == 0 { return INVALID, 0, 0; }
    return OK, prefix + body, id;
}

// Encode one PUBACK/PUBREC/PUBREL/PUBCOMP into a caller-owned buffer. Returns
// status and bytes written (4 on success). out must not be used as a staging
// alias for unrelated live data the caller still needs; the function writes
// only after validation succeeds.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — kind not in {4,5,6,7}; packet_id not in 1..65535
//   NO_SPACE — out shorter than 4 bytes
fn encode_pubresp(kind: i64, packet_id: i64, out: u8[:]) -> i64, i64 {
    if !valid_pubresp_kind(kind) { return INVALID, 0; }
    if packet_id < 1 || packet_id > 65535 { return INVALID, 0; }
    if out.len < 4 { return NO_SPACE, 0; }
    out[0] = ((kind * 16) + pubresp_flags(kind)) as u8;
    out[1] = 2;
    out[2] = (packet_id / 256) as u8;
    out[3] = (packet_id % 256) as u8;
    return OK, 4;
}

// Parse one MQTT 3.1.1 UNSUBACK (OASIS MQTT 3.1.1 §§2.2.2–2.2.3, 2.3.1, 3.11).
// Exactly four bytes on the wire when Remaining Length is encoded minimally:
// type/flags 0xb0, 0x02, Packet Identifier MSB, LSB. There is no payload. On
// success returns (OK, 4, packet_id). On any error consumed and packet_id are
// zero; trailing bytes stay unconsumed. Status precedence matches pubresp
// (fixed type 11, flags 0) without a caller-supplied kind.
//
// Failure precedence (first match wins; consumed and packet_id are always 0):
//   propagate header() status (INCOMPLETE/INVALID for truncated or illegal
//          fixed-header/flags/non-minimal Remaining Length)
//   INVALID — packet type ≠ UNSUBACK (11); or Remaining Length ≠ 2 (even if
//             the body bytes have not arrived yet, once the header is complete)
//   INCOMPLETE — header OK and RL==2 but identifier bytes are missing
//   INVALID — Packet Identifier == 0
fn unsuback(input: const u8[:]) -> i64, i64, i64 {
    let status, prefix, body = header(input);
    if status != OK { return status, 0, 0; }
    if input[0] / 16 != 11 || body != 2 { return INVALID, 0, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0, 0; }
    let id = (input[prefix] as i64) * 256 + input[prefix + 1];
    if id == 0 { return INVALID, 0, 0; }
    return OK, prefix + body, id;
}

// Encode one UNSUBACK into a caller-owned buffer. Returns status and bytes
// written (4 on success). Writes only after validation succeeds.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — packet_id not in 1..65535
//   NO_SPACE — out shorter than 4 bytes
fn encode_unsuback(packet_id: i64, out: u8[:]) -> i64, i64 {
    if packet_id < 1 || packet_id > 65535 { return INVALID, 0; }
    if out.len < 4 { return NO_SPACE, 0; }
    out[0] = 0xb0;
    out[1] = 2;
    out[2] = (packet_id / 256) as u8;
    out[3] = (packet_id % 256) as u8;
    return OK, 4;
}

// MQTT 3.1.1 PINGREQ / PINGRESP / DISCONNECT (OASIS §§2.2, 3.12–3.14).
// Each is exactly two bytes when Remaining Length is encoded minimally:
// type/flags with reserved flags 0, then Remaining Length 0. No variable
// header or payload. Shared helpers keep the three typed APIs aligned.
const PINGREQ = 12;
const PINGRESP = 13;
const DISCONNECT = 14;

fn empty_control(input: const u8[:], kind: i64) -> i64, i64 {
    let status, prefix, body = header(input);
    if status != OK { return status, 0; }
    // Wrong type or nonzero Remaining Length is INVALID once the header is
    // complete, even if later body bytes (for a nonzero RL) have not arrived.
    if input[0] / 16 != kind || body != 0 { return INVALID, 0; }
    return OK, prefix;
}

fn encode_empty_control(first: u8, out: u8[:]) -> i64, i64 {
    if out.len < 2 { return NO_SPACE, 0; }
    out[0] = first;
    out[1] = 0;
    return OK, 2;
}

// Parse one PINGREQ. On success returns (OK, 2). On any error consumed is 0;
// trailing bytes after a complete packet stay unconsumed.
//
// Failure precedence (first match wins; consumed is always 0 on error):
//   propagate header() status (INCOMPLETE/INVALID for truncated or illegal
//          fixed-header/flags/non-minimal Remaining Length)
//   INVALID — packet type ≠ PINGREQ (12); or Remaining Length ≠ 0
fn pingreq(input: const u8[:]) -> i64, i64 {
    return empty_control(input, PINGREQ);
}

// Encode one PINGREQ (`C0 00`) into a caller-owned buffer.
// Failure: NO_SPACE if out is shorter than 2; out unchanged.
fn encode_pingreq(out: u8[:]) -> i64, i64 {
    return encode_empty_control(0xc0, out);
}

// Parse one PINGRESP. On success returns (OK, 2). Same failure precedence as
// pingreq with type PINGRESP (13) and fixed header `D0 00`.
fn pingresp(input: const u8[:]) -> i64, i64 {
    return empty_control(input, PINGRESP);
}

// Encode one PINGRESP (`D0 00`). Failure: NO_SPACE if out shorter than 2.
fn encode_pingresp(out: u8[:]) -> i64, i64 {
    return encode_empty_control(0xd0, out);
}

// Parse one DISCONNECT. On success returns (OK, 2). Same failure precedence as
// pingreq with type DISCONNECT (14) and fixed header `E0 00`. No session or
// Will-clearance policy is applied.
fn disconnect(input: const u8[:]) -> i64, i64 {
    return empty_control(input, DISCONNECT);
}

// Encode one DISCONNECT (`E0 00`). Failure: NO_SPACE if out shorter than 2.
fn encode_disconnect(out: u8[:]) -> i64, i64 {
    return encode_empty_control(0xe0, out);
}
