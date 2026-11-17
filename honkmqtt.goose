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
