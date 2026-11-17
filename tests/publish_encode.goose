// Independent MQTT 3.1.1 PUBLISH encode wire vectors and failure contracts.
// Expected bytes are asserted before any encode/decode round trip.
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn eq_prefix(got: const u8[:], expect: const u8[:]) {
    assert(got.len >= expect.len);
    for i in expect.len { assert(got[i] == expect[i]); }
}

fn encode_ok(
    dup:       bool,
    qos:       i64,
    retain:    bool,
    topic:     const u8[:],
    packet_id: i64,
    payload:   const u8[:],
    expect:    const u8[:],
) {
    var out: u8[256] = [0; 256];
    fill(out, 0xa5);
    let status, n = honkmqtt::encode_publish(dup, qos, retain, topic, packet_id, payload, out);
    assert(status == honkmqtt::OK && n == expect.len);
    eq_prefix(out[0..n], expect);
    // Trailing bytes on success must remain untouched.
    for i in n..out.len { assert(out[i] == 0xa5); }
    // Round trip supplements the independent vector.
    let ps, used, t, tl, p, id = honkmqtt::publish(out[0..n], expect.len);
    assert(ps == honkmqtt::OK && used == n && tl == topic.len && id == packet_id);
    assert(out[t..t + tl] == topic);
    assert(out[p..used] == payload);
}

fn encode_fail(
    dup:       bool,
    qos:       i64,
    retain:    bool,
    topic:     const u8[:],
    packet_id: i64,
    payload:   const u8[:],
    out:       u8[:],
    expected:  i64,
) {
    fill(out, 0x5a);
    let status, n = honkmqtt::encode_publish(dup, qos, retain, topic, packet_id, payload, out);
    assert(status == expected && n == 0);
    unchanged(out, 0x5a);
}

fn wire_vectors() {
    // QoS 0, topic a/b, 3-byte binary payload (matches tests/publish.goose vector).
    let expect0:  u8[10] = [0x30, 0x08, 0, 3, 'a', '/', 'b', 0, 0xff, 7];
    let payload0: u8[3]  = [0, 0xff, 7];
    encode_ok(false, 0, false, "a/b", 0, payload0, expect0);

    // QoS 1, topic x, id 0x1234, empty payload.
    let expect1: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
    encode_ok(false, 1, false, "x", 0x1234, "", expect1);

    // QoS 2 + DUP, topic x, id 0xffff, empty payload.
    let expect2: u8[7] = [0x3c, 5, 0, 1, 'x', 0xff, 0xff];
    encode_ok(true, 2, false, "x", 65535, "", expect2);

    // RETAIN alone (QoS 0).
    let expect_r: u8[5] = [0x31, 3, 0, 1, 'z'];
    encode_ok(false, 0, true, "z", 0, "", expect_r);

    // DUP + QoS 1 + RETAIN.
    let expect_d: u8[7] = [0x3b, 5, 0, 1, 'x', 0x00, 0x01];
    encode_ok(true, 1, true, "x", 1, "", expect_d);

    // Empty binary-capable payload already covered; nonempty UTF-8 topic.
    let expect_u: u8[7] = [0x30, 5, 0, 3, 0xe2, 0x82, 0xac];
    encode_ok(false, 0, false, [0xe2, 0x82, 0xac], 0, "", expect_u);
}

fn remaining_length_transitions() {
    // Remaining Length 127 uses one RL digit; topic "x" => payload 124.
    var payload127: u8[124] = [0x11; 124];
    var expect127:  u8[129] = [0; 129];
    expect127[0] = 0x30;
    expect127[1] = 127;
    expect127[2] = 0;
    expect127[3] = 1;
    expect127[4] = 'x';
    for i in 124 { expect127[5 + i] = 0x11; }
    encode_ok(false, 0, false, "x", 0, payload127, expect127);

    // Remaining Length 128 uses two RL digits (0x80, 0x01); payload 125.
    var payload128: u8[125] = [0x22; 125];
    var expect128:  u8[131] = [0; 131];
    expect128[0] = 0x30;
    expect128[1] = 0x80;
    expect128[2] = 1;
    expect128[3] = 0;
    expect128[4] = 1;
    expect128[5] = 'x';
    for i in 125 { expect128[6 + i] = 0x22; }
    encode_ok(false, 0, false, "x", 0, payload128, expect128);
}

fn failures_and_sentinels() {
    var out: u8[32] = [0; 32];
    // Bad QoS.
    encode_fail(false, 3, false, "a", 0, "", out, honkmqtt::INVALID);
    encode_fail(false, -1, false, "a", 0, "", out, honkmqtt::INVALID);
    // DUP with QoS 0.
    encode_fail(true, 0, false, "a", 0, "", out, honkmqtt::INVALID);
    // Topic invalid.
    encode_fail(false, 0, false, "", 0, "", out, honkmqtt::INVALID);
    encode_fail(false, 0, false, "+", 0, "", out, honkmqtt::INVALID);
    encode_fail(false, 0, false, [0], 0, "", out, honkmqtt::INVALID);
    // Packet id rules.
    encode_fail(false, 0, false, "a", 1, "", out, honkmqtt::INVALID);
    encode_fail(false, 1, false, "a", 0, "", out, honkmqtt::INVALID);
    encode_fail(false, 2, false, "a", 65536, "", out, honkmqtt::INVALID);
    // NO_SPACE: exact undersize leaves sentinel intact.
    var tiny: u8[4] = [0; 4];
    encode_fail(false, 0, false, "a", 0, "", tiny, honkmqtt::NO_SPACE);
    // Exact fit succeeds.
    var exact: u8[5] = [0; 5];
    fill(exact, 0x3c);
    let st, n = honkmqtt::encode_publish(false, 0, false, "a", 0, "", exact);
    assert(st == honkmqtt::OK && n == 5);
    let expect: u8[5] = [0x30, 3, 0, 1, 'a'];
    eq_prefix(exact, expect);
}

fn adjacent_and_opaque_compat() {
    // Encoded PUBLISH followed by an independent PINGREQ in the same buffer.
    var buf: u8[16] = [0; 16];
    fill(buf, 0xee);
    let expect: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
    let st, n = honkmqtt::encode_publish(false, 1, false, "x", 0x1234, "", buf);
    assert(st == honkmqtt::OK && n == 7);
    eq_prefix(buf[0..n], expect);
    let es, en = honkmqtt::encode(0xc0, "", buf[n..n + 2]);
    assert(es == honkmqtt::OK && en == 2);
    assert(buf[7] == 0xc0 && buf[8] == 0);
    for i in 9..buf.len { assert(buf[i] == 0xee); }
    // Truncated view of the PUBLISH remains incomplete for the parser.
    let ps, _, _, _, _, _ = honkmqtt::publish(buf[0..6], 5);
    assert(ps == honkmqtt::INCOMPLETE);
    // Full PUBLISH still parses; trailing PINGREQ is unconsumed.
    let ok, used, _, _, _, id = honkmqtt::publish(buf[0..9], 5);
    assert(ok == honkmqtt::OK && used == 7 && id == 0x1234);
}

fn main() {
    wire_vectors();
    remaining_length_transitions();
    failures_and_sentinels();
    adjacent_and_opaque_compat();
    print("PUBLISH encode tests passed");
}
