namespace honkmqtt;
import .wire;
import .topics;

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
