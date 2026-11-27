namespace honkmqtt;
import .wire;
import .topics;

// MQTT 3.1.1 SUBSCRIBE / SUBACK (OASIS §§2.2–2.3.1, 3.8–3.9, 4.7).
const SUBSCRIBE_MIN_REMAINING = 6;
const SUBACK_MIN_REMAINING = 3;
const SUBACK_QOS0 = 0;
const SUBACK_QOS1 = 1;
const SUBACK_QOS2 = 2;
const SUBACK_FAILURE = 128;

fn subscribe_fail(st: i64) -> i64, i64, i64, i64, i64 {
    return st, 0, 0, 0, 0;
}

fn suback_fail(st: i64) -> i64, i64, i64, i64, i64 {
    return st, 0, 0, 0, 0;
}

fn valid_suback_code(code: i64) -> bool {
    return code == SUBACK_QOS0 || code == SUBACK_QOS1 || code == SUBACK_QOS2 || code == SUBACK_FAILURE;
}

// Walk one SUBSCRIBE Topic Filter / Requested QoS entry inside [pos, end).
// On success returns (OK, next_pos, filter_off, filter_len, qos). Offsets refer
// to `input`. On failure returns (INVALID, 0, 0, 0, 0). A length that runs past
// `end` is INVALID (Remaining Length already known complete when used after
// subscribe()). Callers stop when pos == end after a successful subscribe().
fn subscribe_next(input: const u8[:], pos: i64, end: i64) -> i64, i64, i64, i64, i64 {
    if pos < 0 || end < pos || end > input.len { return INVALID, 0, 0, 0, 0; }
    let st, off, len, after = take_prefixed(input, pos, end);
    if st != OK { return INVALID, 0, 0, 0, 0; }
    if after >= end { return INVALID, 0, 0, 0, 0; }
    if !valid_filter(input[off..off + len]) { return INVALID, 0, 0, 0, 0; }
    let qos = input[after] as i64;
    // Requested QoS byte must be exactly 0..2 (reserved upper bits clear).
    if qos > 2 { return INVALID, 0, 0, 0, 0; }
    return OK, after + 1, off, len, qos;
}

// Validate a pre-encoded SUBSCRIBE payload list (one or more filter/QoS pairs).
// Nonempty is required; subscribe_next advances strictly and cannot overrun `end`.
fn valid_subscribe_list(list: const u8[:]) -> bool {
    if list.len == 0 { return false; }
    var pos = 0;
    while pos < list.len {
        let st, next, _, _, _ = subscribe_next(list, pos, list.len);
        if st != OK { return false; }
        pos = next;
    }
    return true;
}

fn valid_suback_codes(codes: const u8[:]) -> bool {
    if codes.len == 0 { return false; }
    for c in codes {
        if !valid_suback_code(c) { return false; }
    }
    return true;
}

// Parse one MQTT 3.1.1 SUBSCRIBE without copying. On success returns
// (OK, consumed, packet_id, list_off, list_len). The Topic Filter / QoS list is
// input[list_off..list_off + list_len]; walk it with subscribe_next. Offsets
// refer to `input`, which must remain available. Duplicate filters are accepted
// structurally. Pairing with SUBACK and session behavior are out of scope.
//
// Failure precedence (first match wins; all other results are zero):
//   INVALID — max_body < 0
//   propagate header() status
//   INVALID — type ≠ SUBSCRIBE (8)
//   INVALID — Remaining Length > max_body
//   INVALID — Remaining Length < SUBSCRIBE_MIN_REMAINING (6), before body
//             availability
//   INCOMPLETE — header OK and RL in range but body bytes are missing
//   INVALID — Packet Identifier == 0; empty list; malformed filter/QoS entry;
//             reserved QoS bits; or bytes left/unparsed inside Remaining Length
fn subscribe(input: const u8[:], max_body: i64) -> i64, i64, i64, i64, i64 {
    if max_body < 0 { return subscribe_fail(INVALID); }
    let status, prefix, body = header(input);
    if status != OK { return subscribe_fail(status); }
    if input[0] / 16 != 8 { return subscribe_fail(INVALID); }
    if body > max_body { return subscribe_fail(INVALID); }
    if body < SUBSCRIBE_MIN_REMAINING { return subscribe_fail(INVALID); }
    if input.len - prefix < body { return subscribe_fail(INCOMPLETE); }
    let end = prefix + body;
    let id = (input[prefix] as i64) * 256 + input[prefix + 1];
    if id == 0 { return subscribe_fail(INVALID); }
    let list_off = prefix + 2;
    if !valid_subscribe_list(input[list_off..end]) { return subscribe_fail(INVALID); }
    return OK, end, id, list_off, end - list_off;
}

// Encode one SUBSCRIBE into a caller-owned buffer. `list` is a pre-encoded
// contiguous sequence of Topic Filter / Requested QoS pairs (same layout as the
// SUBSCRIBE payload). out must not overlap list. Validates and sizes first;
// writes only after success is known.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — packet_id not in 1..65535; list.len > MAX_REMAINING-2 (before
//             scanning, so size stays bounded); list empty or malformed;
//             then NO_SPACE if out is short
//   NO_SPACE — out shorter than the encoded packet
fn encode_subscribe(packet_id: i64, list: const u8[:], out: u8[:]) -> i64, i64 {
    if packet_id < 1 || packet_id > 65535 { return INVALID, 0; }
    if list.len > MAX_REMAINING - 2 { return INVALID, 0; }
    if !valid_subscribe_list(list) { return INVALID, 0; }
    let remaining = 2 + list.len;

    var prefix: u8[5] = [0; 5];
    prefix[0] = 0x82;
    var n = remaining;
    var width = 1;
    loop {
        var digit = n % 128;
        n = n / 128;
        if n > 0 { digit += 128; }
        prefix[width] = digit as u8;
        width += 1;
        if n == 0 { break; }
    }
    let need = width + remaining;
    if out.len < need { return NO_SPACE, 0; }
    for i in width { out[i] = prefix[i]; }
    out[width] = (packet_id / 256) as u8;
    out[width + 1] = (packet_id % 256) as u8;
    for i in list.len { out[width + 2 + i] = list[i]; }
    return OK, need;
}

// Parse one MQTT 3.1.1 SUBACK without copying. On success returns
// (OK, consumed, packet_id, codes_off, codes_len). Return codes are
// input[codes_off..codes_off + codes_len], each in {0,1,2,0x80}. Order is
// preserved; count matching against a prior SUBSCRIBE is the caller's concern.
//
// Failure precedence (first match wins; all other results are zero):
//   INVALID — max_body < 0
//   propagate header() status
//   INVALID — type ≠ SUBACK (9)
//   INVALID — Remaining Length > max_body
//   INVALID — Remaining Length < SUBACK_MIN_REMAINING (3), before body
//             availability
//   INCOMPLETE — header OK and RL in range but body bytes are missing
//   INVALID — Packet Identifier == 0; empty code list; or reserved return code
fn suback(input: const u8[:], max_body: i64) -> i64, i64, i64, i64, i64 {
    if max_body < 0 { return suback_fail(INVALID); }
    let status, prefix, body = header(input);
    if status != OK { return suback_fail(status); }
    if input[0] / 16 != 9 { return suback_fail(INVALID); }
    if body > max_body { return suback_fail(INVALID); }
    if body < SUBACK_MIN_REMAINING { return suback_fail(INVALID); }
    if input.len - prefix < body { return suback_fail(INCOMPLETE); }
    let end = prefix + body;
    let id = (input[prefix] as i64) * 256 + input[prefix + 1];
    if id == 0 { return suback_fail(INVALID); }
    let codes_off = prefix + 2;
    if !valid_suback_codes(input[codes_off..end]) { return suback_fail(INVALID); }
    return OK, end, id, codes_off, end - codes_off;
}

// Encode one SUBACK into a caller-owned buffer. `codes` is the pre-encoded
// return-code payload (one or more bytes in {0,1,2,0x80}). out must not overlap
// codes. Validates and sizes first; writes only after success is known.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — packet_id not in 1..65535; codes.len > MAX_REMAINING-2 (before
//             scanning); codes empty or reserved values; then NO_SPACE
//   NO_SPACE — out shorter than the encoded packet
fn encode_suback(packet_id: i64, codes: const u8[:], out: u8[:]) -> i64, i64 {
    if packet_id < 1 || packet_id > 65535 { return INVALID, 0; }
    if codes.len > MAX_REMAINING - 2 { return INVALID, 0; }
    if !valid_suback_codes(codes) { return INVALID, 0; }
    let remaining = 2 + codes.len;

    var prefix: u8[5] = [0; 5];
    prefix[0] = 0x90;
    var n = remaining;
    var width = 1;
    loop {
        var digit = n % 128;
        n = n / 128;
        if n > 0 { digit += 128; }
        prefix[width] = digit as u8;
        width += 1;
        if n == 0 { break; }
    }
    let need = width + remaining;
    if out.len < need { return NO_SPACE, 0; }
    for i in width { out[i] = prefix[i]; }
    out[width] = (packet_id / 256) as u8;
    out[width + 1] = (packet_id % 256) as u8;
    for i in codes.len { out[width + 2 + i] = codes[i]; }
    return OK, need;
}

// MQTT 3.1.1 UNSUBSCRIBE / UNSUBACK (OASIS §§2.2–2.3.1, 3.10–3.11, 4.7).
const UNSUBSCRIBE_MIN_REMAINING = 5;

fn unsubscribe_fail(st: i64) -> i64, i64, i64, i64, i64 {
    return st, 0, 0, 0, 0;
}

// Walk one UNSUBSCRIBE Topic Filter entry inside [pos, end). On success returns
// (OK, next_pos, filter_off, filter_len). Offsets refer to `input`. On failure
// returns (INVALID, 0, 0, 0). A length that runs past `end` is INVALID
// (Remaining Length already known complete when used after unsubscribe()).
// Callers stop when pos == end after a successful unsubscribe().
fn unsubscribe_next(input: const u8[:], pos: i64, end: i64) -> i64, i64, i64, i64 {
    if pos < 0 || end < pos || end > input.len { return INVALID, 0, 0, 0; }
    let st, off, len, after = take_prefixed(input, pos, end);
    if st != OK { return INVALID, 0, 0, 0; }
    if !valid_filter(input[off..off + len]) { return INVALID, 0, 0, 0; }
    return OK, after, off, len;
}

// Validate a pre-encoded UNSUBSCRIBE payload list (one or more Topic Filters).
// Nonempty is required; unsubscribe_next advances strictly and cannot overrun.
fn valid_unsubscribe_list(list: const u8[:]) -> bool {
    if list.len == 0 { return false; }
    var pos = 0;
    while pos < list.len {
        let st, next, _, _ = unsubscribe_next(list, pos, list.len);
        if st != OK { return false; }
        pos = next;
    }
    return true;
}

// Parse one MQTT 3.1.1 UNSUBSCRIBE without copying. On success returns
// (OK, consumed, packet_id, list_off, list_len). The Topic Filter list is
// input[list_off..list_off + list_len]; walk it with unsubscribe_next. Offsets
// refer to `input`, which must remain available. Duplicate filters are accepted
// structurally. Pairing with UNSUBACK and session behavior are out of scope.
//
// Failure precedence (first match wins; all other results are zero):
//   INVALID — max_body < 0
//   propagate header() status
//   INVALID — type ≠ UNSUBSCRIBE (10)
//   INVALID — Remaining Length > max_body
//   INVALID — Remaining Length < UNSUBSCRIBE_MIN_REMAINING (5), before body
//             availability
//   INCOMPLETE — header OK and RL in range but body bytes are missing
//   INVALID — Packet Identifier == 0; empty list; malformed filter entry; or
//             bytes left/unparsed inside Remaining Length
fn unsubscribe(input: const u8[:], max_body: i64) -> i64, i64, i64, i64, i64 {
    if max_body < 0 { return unsubscribe_fail(INVALID); }
    let status, prefix, body = header(input);
    if status != OK { return unsubscribe_fail(status); }
    if input[0] / 16 != 10 { return unsubscribe_fail(INVALID); }
    if body > max_body { return unsubscribe_fail(INVALID); }
    if body < UNSUBSCRIBE_MIN_REMAINING { return unsubscribe_fail(INVALID); }
    if input.len - prefix < body { return unsubscribe_fail(INCOMPLETE); }
    let end = prefix + body;
    let id = (input[prefix] as i64) * 256 + input[prefix + 1];
    if id == 0 { return unsubscribe_fail(INVALID); }
    let list_off = prefix + 2;
    if !valid_unsubscribe_list(input[list_off..end]) { return unsubscribe_fail(INVALID); }
    return OK, end, id, list_off, end - list_off;
}

// Encode one UNSUBSCRIBE into a caller-owned buffer. `list` is a pre-encoded
// contiguous sequence of Topic Filters (same layout as the UNSUBSCRIBE
// payload; no QoS bytes). out must not overlap list. Validates and sizes
// first; writes only after success is known.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — packet_id not in 1..65535; list.len > MAX_REMAINING-2 (before
//             scanning, so size stays bounded); list empty or malformed
//   NO_SPACE — out shorter than the encoded packet
fn encode_unsubscribe(packet_id: i64, list: const u8[:], out: u8[:]) -> i64, i64 {
    if packet_id < 1 || packet_id > 65535 { return INVALID, 0; }
    if list.len > MAX_REMAINING - 2 { return INVALID, 0; }
    if !valid_unsubscribe_list(list) { return INVALID, 0; }
    let remaining = 2 + list.len;

    var prefix: u8[5] = [0; 5];
    prefix[0] = 0xa2;
    var n = remaining;
    var width = 1;
    loop {
        var digit = n % 128;
        n = n / 128;
        if n > 0 { digit += 128; }
        prefix[width] = digit as u8;
        width += 1;
        if n == 0 { break; }
    }
    let need = width + remaining;
    if out.len < need { return NO_SPACE, 0; }
    for i in width { out[i] = prefix[i]; }
    out[width] = (packet_id / 256) as u8;
    out[width + 1] = (packet_id % 256) as u8;
    for i in list.len { out[width + 2 + i] = list[i]; }
    return OK, need;
}
