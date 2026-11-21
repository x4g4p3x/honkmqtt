namespace honkmqtt;

// Status codes shared by the buffer-oriented API.
const OK = 0;
const INCOMPLETE = 1;
const INVALID = 2;
const NO_SPACE = 3;
const MAX_REMAINING = 268435455;

// Decode one complete fixed header. Returns status, header length, body length.
// An incomplete result consumes nothing; the caller retains and extends the buffer.
fn header(input: const u8[:]) -> i64, i64, i64 {
    if input.len < 1 { return INCOMPLETE, 0, 0; }
    let kind = input[0] / 16;
    let flags = input[0] % 16;
    if kind == 0 || kind == 15 { return INVALID, 0, 0; }
    if kind == 3 {
        let qos = (flags / 2) % 4;
        if qos == 3 || (qos == 0 && flags >= 8) { return INVALID, 0, 0; }
    } else if kind == 6 || kind == 8 || kind == 10 {
        if flags != 2 { return INVALID, 0, 0; }
    } else if flags != 0 { return INVALID, 0, 0; }
    var value = 0;
    var factor = 1;
    for i in 4 {
        if input.len <= i + 1 { return INCOMPLETE, 0, 0; }
        let digit = input[i + 1] as i64;
        value += (digit % 128) * factor;
        if digit < 128 {
            // Reject non-minimal encodings to avoid ambiguous framing.
            if i > 0 && digit == 0 { return INVALID, 0, 0; }
            return OK, i + 2, value;
        }
        factor *= 128;
    }
    return INVALID, 0, 0;
}

// Decode the first frame, without copying. Its bytes are input[0..consumed].
// max_body bounds memory committed by the transport; negative values are invalid.
fn frame(input: const u8[:], max_body: i64) -> i64, i64 {
    if max_body < 0 { return INVALID, 0; }
    let status, prefix, body = header(input);
    if status != OK { return status, 0; }
    if body > max_body { return INVALID, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0; }
    return OK, prefix + body;
}

// Write a fixed header and opaque body. Returns status and bytes written.
// Output must not overlap body. This checks framing flags, not packet semantics.
fn encode(first: u8, body: const u8[:], out: u8[:]) -> i64, i64 {
    if body.len > MAX_REMAINING { return INVALID, 0; }
    var prefix: u8[5] = [0; 5];
    prefix[0] = first;
    var n = body.len;
    var width = 1;
    loop {
        var digit = n % 128;
        n = n / 128;
        if n > 0 { digit += 128; }
        prefix[width] = digit as u8;
        width += 1;
        if n == 0 { break; }
    }
    let status, _, _ = header(prefix[0..width]);
    if status != OK { return INVALID, 0; }
    if out.len < width + body.len { return NO_SPACE, 0; }
    for i in width { out[i] = prefix[i]; }
    for i in body.len { out[width + i] = body[i]; }
    return OK, width + body.len;
}

// MQTT strings use well-formed UTF-8 and cannot contain U+0000.
fn valid_utf8(text: const u8[:]) -> bool {
    var i = 0;
    while i < text.len {
        let a = text[i] as i64;
        if a == 0 { return false; }
        if a < 128 { i += 1; continue; }
        var count = 0;
        var value = 0;
        var minimum = 0;
        if a >= 194 && a <= 223 { count = 2; value = a - 192; minimum = 128; }
        else if a >= 224 && a <= 239 { count = 3; value = a - 224; minimum = 2048; }
        else if a >= 240 && a <= 244 { count = 4; value = a - 240; minimum = 65536; }
        else { return false; }
        if text.len - i < count { return false; }
        for j in 1..count {
            let b = text[i + j] as i64;
            if b < 128 || b > 191 { return false; }
            value = value * 64 + b - 128;
        }
        if value < minimum || value > 1114111 || (value >= 55296 && value <= 57343) { return false; }
        i += count;
    }
    return true;
}

// Topic names and filters are length-bounded MQTT UTF-8 strings.
fn valid_topic(topic: const u8[:]) -> bool {
    if topic.len == 0 || topic.len > 65535 || !valid_utf8(topic) { return false; }
    for c in topic { if c == 0 || c == '+' || c == '#' { return false; } }
    return true;
}

fn valid_filter(filter: const u8[:]) -> bool {
    if filter.len == 0 || filter.len > 65535 || !valid_utf8(filter) { return false; }
    for c, i in filter {
        if c == 0 { return false; }
        if c == '#' {
            if i != filter.len - 1 || (i > 0 && filter[i - 1] != '/') { return false; }
        }
        if c == '+' {
            if (i > 0 && filter[i - 1] != '/') || (i + 1 < filter.len && filter[i + 1] != '/') { return false; }
        }
    }
    return true;
}

// Encode one MQTT 3.1.1 PUBLISH (OASIS MQTT 3.1.1 §§1.5.3, 2.2.3, 2.3.1, 3.3,
// 4.7) into a caller-owned buffer. Returns status and bytes written.
//
// Ownership: topic and payload are borrowed; out is caller-owned. out must not
// overlap topic or payload. The function never allocates a full-body staging
// buffer: it validates and sizes first, then writes only after success is known.
//
// Failure precedence (first match wins; out is left unchanged on every error):
//   INVALID — qos not in {0,1,2}; DUP set with QoS 0; topic fails valid_topic;
//             packet_id must be 0 for QoS 0 and in 1..65535 for QoS 1/2;
//             Remaining Length would exceed MAX_REMAINING
//   NO_SPACE — out is shorter than the encoded packet
// Compatible with publish(): successful output is accepted by publish when
// max_body is large enough. The opaque encode() API remains for non-PUBLISH
// framing and does not gain PUBLISH body validation.
fn encode_publish(
    dup:       bool,
    qos:       i64,
    retain:    bool,
    topic:     const u8[:],
    packet_id: i64,
    payload:   const u8[:],
    out:       u8[:],
) -> i64, i64 {
    if qos < 0 || qos > 2 { return INVALID, 0; }
    if dup && qos == 0 { return INVALID, 0; }
    if !valid_topic(topic) { return INVALID, 0; }
    if qos == 0 {
        if packet_id != 0 { return INVALID, 0; }
    } else if packet_id < 1 || packet_id > 65535 {
        return INVALID, 0;
    }
    // Remaining Length = 2-byte topic length + topic + optional id + payload.
    var remaining = 2 + topic.len + payload.len;
    if qos > 0 { remaining += 2; }
    if remaining > MAX_REMAINING { return INVALID, 0; }

    var first = 0x30 as u8;
    if retain { first += 1; }
    first += (qos * 2) as u8;
    if dup { first += 8; }

    var prefix: u8[5] = [0; 5];
    prefix[0] = first;
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
    var o = width;
    out[o] = (topic.len / 256) as u8;
    out[o + 1] = (topic.len % 256) as u8;
    o += 2;
    for i in topic.len { out[o + i] = topic[i]; }
    o += topic.len;
    if qos > 0 {
        out[o] = (packet_id / 256) as u8;
        out[o + 1] = (packet_id % 256) as u8;
        o += 2;
    }
    for i in payload.len { out[o + i] = payload[i]; }
    return OK, need;
}

// Parse one MQTT 3.1.1 PUBLISH without copying. On success returns status,
// consumed bytes, topic offset, topic length, payload offset, packet identifier.
// The payload ends at consumed; identifier is zero for QoS 0. Offsets refer to
// input, which must stay available while the caller uses them. On any error all
// other results are zero. max_body limits the MQTT remaining length.
fn publish(input: const u8[:], max_body: i64) -> i64, i64, i64, i64, i64, i64 {
    if max_body < 0 { return INVALID, 0, 0, 0, 0, 0; }
    let status, prefix, body = header(input);
    if status != OK { return status, 0, 0, 0, 0, 0; }
    if input[0] / 16 != 3 || body > max_body { return INVALID, 0, 0, 0, 0, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0, 0, 0, 0, 0; }
    if body < 2 { return INVALID, 0, 0, 0, 0, 0; }
    let end = prefix + body;
    let topic_len = (input[prefix] as i64) * 256 + input[prefix + 1];
    let topic_start = prefix + 2;
    if topic_len > end - topic_start { return INVALID, 0, 0, 0, 0, 0; }
    let topic_end = topic_start + topic_len;
    if !valid_topic(input[topic_start..topic_end]) { return INVALID, 0, 0, 0, 0, 0; }
    let qos = (input[0] / 2) % 4;
    var payload_start = topic_end;
    var identifier = 0;
    if qos > 0 {
        if end - payload_start < 2 { return INVALID, 0, 0, 0, 0, 0; }
        identifier = (input[payload_start] as i64) * 256 + input[payload_start + 1];
        if identifier == 0 { return INVALID, 0, 0, 0, 0, 0; }
        payload_start += 2;
    }
    return OK, end, topic_start, topic_len, payload_start, identifier;
}

// MQTT 3.1.1 CONNECT Protocol Level for this codec (OASIS §3.1.2.2).
const CONNECT_PROTOCOL_LEVEL = 4;
// Structural Remaining Length bounds for CONNECT: 10-byte variable header plus
// Client ID and up to four optional length-prefixed fields, each at most
// 2+65535 bytes → 10 + 5*65537 = 327695 (OASIS §§1.5.3, 3.1.2–3.1.3).
const CONNECT_MIN_REMAINING = 12;
const CONNECT_MAX_REMAINING = 327695;

fn connect_fail(st: i64) -> i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 {
    return st, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0;
}

// Read a 2-byte big-endian length-prefixed field inside [pos, end).
// On success returns (OK, data_offset, data_length, next_pos). On failure
// returns (INVALID, 0, 0, 0). A length that runs past `end` is INVALID (the
// enclosing Remaining Length is already known to be complete).
fn take_prefixed(input: const u8[:], pos: i64, end: i64) -> i64, i64, i64, i64 {
    if end - pos < 2 { return INVALID, 0, 0, 0; }
    let n = (input[pos] as i64) * 256 + input[pos + 1];
    let start = pos + 2;
    if n > end - start { return INVALID, 0, 0, 0; }
    return OK, start, n, start + n;
}

// Parse one MQTT 3.1.1 CONNECT (OASIS MQTT 3.1.1 §§1.5.3, 2.2, 3.1) without
// copying. On success returns:
//   (OK, consumed, connect_flags, keep_alive,
//    client_id_off, client_id_len,
//    will_topic_off, will_topic_len,
//    will_message_off, will_message_len,
//    username_off, username_len,
//    password_off, password_len)
// Offsets refer to `input`, which must remain available. Absent optional
// fields use off=0,len=0. Present-empty UTF-8/binary fields use len=0 with
// off at the first data position (immediately after the length prefix).
// `connect_flags` is the validated Connect Flags byte (reserved bit 0 is 0).
//
// Wire constraints enforced here: Protocol Name "MQTT"; Protocol Level 4;
// reserved Connect Flag clear; Will/User/Password flag and field consistency;
// Will QoS in 0..2 when Will is set and 0 when clear; Client ID is MQTT UTF-8;
// empty Client ID requires Clean Session; Will Topic is a valid topic name;
// User Name is MQTT UTF-8; Will Message and Password are opaque length-prefixed
// binary; payload fields consume the Remaining Length exactly. Client ID
// character-set / 1..23-byte server acceptance policy (MQTT-3.1.3-5) is not
// applied—any well-formed UTF-8 Client ID is accepted structurally.
//
// Failure precedence (first match wins; all other results are zero):
//   INVALID — max_body < 0
//   propagate header() status
//   INVALID — type ≠ CONNECT (1)
//   INVALID — Remaining Length > max_body
//   INVALID — Remaining Length < CONNECT_MIN_REMAINING or
//             > CONNECT_MAX_REMAINING (after a complete header, before body
//             availability—so an impossible RL never returns INCOMPLETE)
//   INCOMPLETE — header OK and RL in range but body bytes are missing
//   INVALID — malformed variable header/payload (protocol identity/level,
//     flags, lengths past the body, UTF-8/topic rules, empty Client ID without
//     Clean Session, or bytes left/unparsed inside Remaining Length)
fn connect(input: const u8[:], max_body: i64) -> i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 {
    if max_body < 0 { return connect_fail(INVALID); }
    let status, prefix, body = header(input);
    if status != OK { return connect_fail(status); }
    if input[0] / 16 != 1 { return connect_fail(INVALID); }
    if body > max_body { return connect_fail(INVALID); }
    if body < CONNECT_MIN_REMAINING || body > CONNECT_MAX_REMAINING {
        return connect_fail(INVALID);
    }
    if input.len - prefix < body { return connect_fail(INCOMPLETE); }
    let end = prefix + body;
    var pos = prefix;

    let st_name, name_off, name_len, after_name = take_prefixed(input, pos, end);
    if st_name != OK || name_len != 4 { return connect_fail(INVALID); }
    if input[name_off] != 'M' || input[name_off + 1] != 'Q'
        || input[name_off + 2] != 'T' || input[name_off + 3] != 'T' {
        return connect_fail(INVALID);
    }
    pos = after_name;
    if end - pos < 4 { return connect_fail(INVALID); }
    if input[pos] != CONNECT_PROTOCOL_LEVEL { return connect_fail(INVALID); }
    let flags = input[pos + 1] as i64;
    pos += 2;
    if (flags & 1) != 0 { return connect_fail(INVALID); }
    let will = (flags & 4) != 0;
    let will_qos = (flags / 8) % 4;
    let will_retain = (flags & 32) != 0;
    let has_pass = (flags & 64) != 0;
    let has_user = (flags & 128) != 0;
    if !will {
        if will_qos != 0 || will_retain { return connect_fail(INVALID); }
    } else if will_qos > 2 {
        return connect_fail(INVALID);
    }
    if has_pass && !has_user { return connect_fail(INVALID); }
    let keep_alive = (input[pos] as i64) * 256 + input[pos + 1];
    pos += 2;

    let st_cid, cid_off, cid_len, after_cid = take_prefixed(input, pos, end);
    if st_cid != OK { return connect_fail(INVALID); }
    if !valid_utf8(input[cid_off..cid_off + cid_len]) { return connect_fail(INVALID); }
    let clean = (flags & 2) != 0;
    if cid_len == 0 && !clean { return connect_fail(INVALID); }
    pos = after_cid;

    var wt_off = 0;
    var wt_len = 0;
    var wm_off = 0;
    var wm_len = 0;
    if will {
        let st_wt, o1, n1, p1 = take_prefixed(input, pos, end);
        if st_wt != OK || !valid_topic(input[o1..o1 + n1]) { return connect_fail(INVALID); }
        wt_off = o1;
        wt_len = n1;
        let st_wm, o2, n2, p2 = take_prefixed(input, p1, end);
        if st_wm != OK { return connect_fail(INVALID); }
        wm_off = o2;
        wm_len = n2;
        pos = p2;
    }

    var user_off = 0;
    var user_len = 0;
    if has_user {
        let st_u, o, n, p = take_prefixed(input, pos, end);
        if st_u != OK || !valid_utf8(input[o..o + n]) { return connect_fail(INVALID); }
        user_off = o;
        user_len = n;
        pos = p;
    }

    var pass_off = 0;
    var pass_len = 0;
    if has_pass {
        let st_p, o, n, p = take_prefixed(input, pos, end);
        if st_p != OK { return connect_fail(INVALID); }
        pass_off = o;
        pass_len = n;
        pos = p;
    }

    if pos != end { return connect_fail(INVALID); }
    return OK, end, flags, keep_alive, cid_off, cid_len, wt_off, wt_len, wm_off, wm_len, user_off, user_len, pass_off, pass_len;
}

// Encode one MQTT 3.1.1 CONNECT into a caller-owned buffer. Returns status and
// bytes written. Protocol Name is always "MQTT" and Protocol Level is always 4.
// `out` must not overlap client_id, will_topic, will_message, username, or
// password. Validates and sizes first; writes only after success is known.
//
// Presence: `will`/`user`/`pass` select optional payload fields. Present-empty
// Client ID, User Name, Password, and Will Message are legal (Client ID empty
// requires clean_session). When `will` is false, will_qos must be 0 and
// will_retain false (will_topic/will_message are ignored). When `user` is
// false, username is ignored. When `pass` is false, password is ignored.
// `pass` requires `user`.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — keep_alive not in 0..65535; Client ID not MQTT UTF-8 or longer
//             than 65535; empty Client ID without clean_session; will/user/pass
//             flag or field rules; Will Topic not a valid topic; binary field
//             longer than 65535; Remaining Length would exceed MAX_REMAINING
//   NO_SPACE — out shorter than the encoded packet
fn encode_connect(
    clean_session: bool,
    keep_alive:    i64,
    client_id:     const u8[:],
    will:          bool,
    will_qos:      i64,
    will_retain:   bool,
    will_topic:    const u8[:],
    will_message:  const u8[:],
    user:          bool,
    username:      const u8[:],
    pass:          bool,
    password:      const u8[:],
    out:           u8[:],
) -> i64, i64 {
    if keep_alive < 0 || keep_alive > 65535 { return INVALID, 0; }
    if client_id.len > 65535 || !valid_utf8(client_id) { return INVALID, 0; }
    if client_id.len == 0 && !clean_session { return INVALID, 0; }
    if will {
        if will_qos < 0 || will_qos > 2 { return INVALID, 0; }
        if !valid_topic(will_topic) { return INVALID, 0; }
        if will_message.len > 65535 { return INVALID, 0; }
    } else if will_qos != 0 || will_retain {
        return INVALID, 0;
    }
    if pass && !user { return INVALID, 0; }
    if user {
        if username.len > 65535 || !valid_utf8(username) { return INVALID, 0; }
    }
    if pass {
        if password.len > 65535 { return INVALID, 0; }
    }

    var remaining = 10 + 2 + client_id.len;
    if will { remaining += 2 + will_topic.len + 2 + will_message.len; }
    if user { remaining += 2 + username.len; }
    if pass { remaining += 2 + password.len; }
    if remaining > MAX_REMAINING { return INVALID, 0; }

    var flags = 0;
    if clean_session { flags += 2; }
    if will {
        flags += 4;
        flags += will_qos * 8;
        if will_retain { flags += 32; }
    }
    if pass { flags += 64; }
    if user { flags += 128; }

    var prefix: u8[5] = [0; 5];
    prefix[0] = 0x10;
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
    var o = width;
    out[o] = 0;
    out[o + 1] = 4;
    out[o + 2] = 'M';
    out[o + 3] = 'Q';
    out[o + 4] = 'T';
    out[o + 5] = 'T';
    out[o + 6] = CONNECT_PROTOCOL_LEVEL;
    out[o + 7] = flags as u8;
    out[o + 8] = (keep_alive / 256) as u8;
    out[o + 9] = (keep_alive % 256) as u8;
    o += 10;
    out[o] = (client_id.len / 256) as u8;
    out[o + 1] = (client_id.len % 256) as u8;
    o += 2;
    for i in client_id.len { out[o + i] = client_id[i]; }
    o += client_id.len;
    if will {
        out[o] = (will_topic.len / 256) as u8;
        out[o + 1] = (will_topic.len % 256) as u8;
        o += 2;
        for i in will_topic.len { out[o + i] = will_topic[i]; }
        o += will_topic.len;
        out[o] = (will_message.len / 256) as u8;
        out[o + 1] = (will_message.len % 256) as u8;
        o += 2;
        for i in will_message.len { out[o + i] = will_message[i]; }
        o += will_message.len;
    }
    if user {
        out[o] = (username.len / 256) as u8;
        out[o + 1] = (username.len % 256) as u8;
        o += 2;
        for i in username.len { out[o + i] = username[i]; }
        o += username.len;
    }
    if pass {
        out[o] = (password.len / 256) as u8;
        out[o + 1] = (password.len % 256) as u8;
        o += 2;
        for i in password.len { out[o + i] = password[i]; }
        o += password.len;
    }
    return OK, need;
}

// MQTT 3.1.1 CONNACK Connect Return codes (OASIS §3.2.2.3). Values 6..255 are
// reserved and rejected by connack()/encode_connack().
const CONNACK_ACCEPTED = 0;
const CONNACK_REFUSED_PROTOCOL = 1;
const CONNACK_REFUSED_IDENTIFIER = 2;
const CONNACK_REFUSED_SERVER = 3;
const CONNACK_REFUSED_CREDENTIALS = 4;
const CONNACK_REFUSED_UNAUTHORIZED = 5;

// Parse one MQTT 3.1.1 CONNACK (OASIS MQTT 3.1.1 §§2.2.2–2.2.3, 3.2). Wire form
// with minimal Remaining Length is exactly four bytes: type/flags 0x20, 0x02,
// Connect Acknowledge Flags, Connect Return code. No payload. On success
// returns (OK, 4, session_present, return_code). On any error consumed is 0,
// session_present is false, and return_code is 0. Trailing bytes stay
// unconsumed. This is structural validation only—not CONNECT pairing or
// session-state policy.
//
// Failure precedence (first match wins):
//   propagate header() status (INCOMPLETE/INVALID for truncated or illegal
//     fixed-header/flags/non-minimal Remaining Length)
//   INVALID — packet type ≠ CONNACK (2); or Remaining Length ≠ 2 (even if the
//     body bytes have not arrived yet, once the header is complete)
//   INCOMPLETE — header OK and RL==2 but acknowledge/return bytes are missing
//   INVALID — body flags/code: bits 1..7 set; return code > 5; or Session
//     Present set when return code ≠ 0
fn connack(input: const u8[:]) -> i64, i64, bool, i64 {
    let status, prefix, body = header(input);
    if status != OK { return status, 0, false, 0; }
    if input[0] / 16 != 2 || body != 2 { return INVALID, 0, false, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0, false, 0; }
    let flags = input[prefix] as i64;
    let code = input[prefix + 1] as i64;
    if (flags & 0xfe) != 0 { return INVALID, 0, false, 0; }
    // `code` is a u8 zero-extended to i64, so it is always >= 0.
    if code > 5 { return INVALID, 0, false, 0; }
    let session = (flags & 1) != 0;
    if code != 0 && session { return INVALID, 0, false, 0; }
    return OK, prefix + body, session, code;
}

// Encode one CONNACK into a caller-owned buffer. Returns status and bytes
// written (4 on success). Writes only after validation succeeds.
//
// Failure precedence (first match wins; out unchanged on every error):
//   INVALID — return_code not in 0..5; or session_present with return_code ≠ 0
//   NO_SPACE — out shorter than 4 bytes
fn encode_connack(session_present: bool, return_code: i64, out: u8[:]) -> i64, i64 {
    if return_code < 0 || return_code > 5 { return INVALID, 0; }
    if return_code != 0 && session_present { return INVALID, 0; }
    if out.len < 4 { return NO_SPACE, 0; }
    out[0] = 0x20;
    out[1] = 2;
    if session_present { out[2] = 1; } else { out[2] = 0; }
    out[3] = return_code as u8;
    return OK, 4;
}

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

// Returns false for invalid UTF-8, topic names, or wildcard syntax.
fn matches(filter: const u8[:], topic: const u8[:]) -> bool {
    if !valid_filter(filter) || !valid_topic(topic) { return false; }
    if topic[0] == '$' && (filter[0] == '+' || filter[0] == '#') { return false; }
    var f = 0;
    var t = 0;
    loop {
        if f < filter.len && filter[f] == '#' { return true; }
        if f < filter.len && filter[f] == '+' {
            f += 1;
            while t < topic.len && topic[t] != '/' { t += 1; }
        } else {
            while f < filter.len && filter[f] != '/' {
                if t >= topic.len || filter[f] != topic[t] { return false; }
                f += 1; t += 1;
            }
        }
        if f == filter.len && t == topic.len { return true; }
        if f < filter.len && filter[f] == '/' && f + 2 == filter.len && filter[f + 1] == '#' && t == topic.len { return true; }
        if f >= filter.len || t >= topic.len || filter[f] != '/' || topic[t] != '/' { return false; }
        f += 1; t += 1;
    }
}
