namespace honkmqtt;
import .wire;
import .topics;

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
