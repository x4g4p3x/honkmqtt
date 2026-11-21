// Independent MQTT 3.1.1 PINGREQ / PINGRESP / DISCONNECT wire vectors
// (OASIS §§2.2, 3.12–3.14). Exact 2-byte forms C0 00, D0 00, E0 00.
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn parse_pingreq_fail(input: const u8[:], expected: i64) {
    let st, used = honkmqtt::pingreq(input);
    assert(st == expected && used == 0);
}

fn parse_pingresp_fail(input: const u8[:], expected: i64) {
    let st, used = honkmqtt::pingresp(input);
    assert(st == expected && used == 0);
}

fn parse_disconnect_fail(input: const u8[:], expected: i64) {
    let st, used = honkmqtt::disconnect(input);
    assert(st == expected && used == 0);
}

fn vector_pingreq(expect: const u8[:]) {
    assert(expect.len == 2);
    let st, used = honkmqtt::pingreq(expect);
    assert(st == honkmqtt::OK && used == 2);

    var with_trail: u8[4] = [0; 4];
    with_trail[0] = expect[0];
    with_trail[1] = expect[1];
    with_trail[2] = 0xd0;
    with_trail[3] = 0x00;
    let st2, used2 = honkmqtt::pingreq(with_trail);
    assert(st2 == honkmqtt::OK && used2 == 2);

    var out: u8[4] = [0; 4];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_pingreq(out);
    assert(es == honkmqtt::OK && en == 2);
    assert(out[0] == expect[0] && out[1] == expect[1]);
    assert(out[2] == 0xa5 && out[3] == 0xa5);
}

fn vector_pingresp(expect: const u8[:]) {
    assert(expect.len == 2);
    let st, used = honkmqtt::pingresp(expect);
    assert(st == honkmqtt::OK && used == 2);

    var with_trail: u8[4] = [0; 4];
    with_trail[0] = expect[0];
    with_trail[1] = expect[1];
    with_trail[2] = 0xc0;
    with_trail[3] = 0x00;
    let st2, used2 = honkmqtt::pingresp(with_trail);
    assert(st2 == honkmqtt::OK && used2 == 2);

    var out: u8[4] = [0; 4];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_pingresp(out);
    assert(es == honkmqtt::OK && en == 2);
    assert(out[0] == expect[0] && out[1] == expect[1]);
    assert(out[2] == 0xa5 && out[3] == 0xa5);
}

fn vector_disconnect(expect: const u8[:]) {
    assert(expect.len == 2);
    let st, used = honkmqtt::disconnect(expect);
    assert(st == honkmqtt::OK && used == 2);

    var with_trail: u8[4] = [0; 4];
    with_trail[0] = expect[0];
    with_trail[1] = expect[1];
    with_trail[2] = 0xc0;
    with_trail[3] = 0x00;
    let st2, used2 = honkmqtt::disconnect(with_trail);
    assert(st2 == honkmqtt::OK && used2 == 2);

    var out: u8[4] = [0; 4];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_disconnect(out);
    assert(es == honkmqtt::OK && en == 2);
    assert(out[0] == expect[0] && out[1] == expect[1]);
    assert(out[2] == 0xa5 && out[3] == 0xa5);
}

fn literal_vectors() {
    let pingreq:  u8[2] = [0xc0, 0x00];
    let pingresp: u8[2] = [0xd0, 0x00];
    let disc:     u8[2] = [0xe0, 0x00];
    vector_pingreq(pingreq);
    vector_pingresp(pingresp);
    vector_disconnect(disc);
}

fn truncations() {
    parse_pingreq_fail("", honkmqtt::INCOMPLETE);
    parse_pingreq_fail([0xc0], honkmqtt::INCOMPLETE);
    parse_pingresp_fail("", honkmqtt::INCOMPLETE);
    parse_pingresp_fail([0xd0], honkmqtt::INCOMPLETE);
    parse_disconnect_fail("", honkmqtt::INCOMPLETE);
    parse_disconnect_fail([0xe0], honkmqtt::INCOMPLETE);
}

fn malformed_pingreq() {
    // Wrong flags / type.
    parse_pingreq_fail([0xc1, 0x00], honkmqtt::INVALID);
    parse_pingreq_fail([0xd0, 0x00], honkmqtt::INVALID);
    parse_pingreq_fail([0xe0, 0x00], honkmqtt::INVALID);
    parse_pingreq_fail([0x30, 0x00], honkmqtt::INVALID);

    // Nonzero Remaining Length (complete header → INVALID even without body).
    parse_pingreq_fail([0xc0, 0x01], honkmqtt::INVALID);
    parse_pingreq_fail([0xc0, 0x01, 0x00], honkmqtt::INVALID);
    parse_pingreq_fail([0xc0, 0x02], honkmqtt::INVALID);

    // Non-minimal Remaining Length encoding of zero.
    parse_pingreq_fail([0xc0, 0x80, 0x00], honkmqtt::INVALID);
}

fn malformed_pingresp() {
    parse_pingresp_fail([0xd1, 0x00], honkmqtt::INVALID);
    parse_pingresp_fail([0xc0, 0x00], honkmqtt::INVALID);
    parse_pingresp_fail([0xe0, 0x00], honkmqtt::INVALID);
    parse_pingresp_fail([0xd0, 0x01], honkmqtt::INVALID);
    parse_pingresp_fail([0xd0, 0x01, 0xff], honkmqtt::INVALID);
    parse_pingresp_fail([0xd0, 0x80, 0x00], honkmqtt::INVALID);
}

fn malformed_disconnect() {
    parse_disconnect_fail([0xe1, 0x00], honkmqtt::INVALID);
    parse_disconnect_fail([0xc0, 0x00], honkmqtt::INVALID);
    parse_disconnect_fail([0xd0, 0x00], honkmqtt::INVALID);
    parse_disconnect_fail([0xe0, 0x01], honkmqtt::INVALID);
    parse_disconnect_fail([0xe0, 0x01, 0x00], honkmqtt::INVALID);
    parse_disconnect_fail([0xe0, 0x80, 0x00], honkmqtt::INVALID);
}

fn encode_sentinels() {
    var out: u8[2] = [0; 2];
    fill(out, 0x5a);
    let es, en = honkmqtt::encode_pingreq(out);
    assert(es == honkmqtt::OK && en == 2 && out[0] == 0xc0 && out[1] == 0x00);

    var tiny: u8[1] = [0xee];
    fill(tiny, 0x5a);
    let n1, w1 = honkmqtt::encode_pingreq(tiny);
    assert(n1 == honkmqtt::NO_SPACE && w1 == 0);
    unchanged(tiny, 0x5a);
    let n2, w2 = honkmqtt::encode_pingresp(tiny);
    assert(n2 == honkmqtt::NO_SPACE && w2 == 0);
    unchanged(tiny, 0x5a);
    let n3, w3 = honkmqtt::encode_disconnect(tiny);
    assert(n3 == honkmqtt::NO_SPACE && w3 == 0);
    unchanged(tiny, 0x5a);

    // Exact capacity.
    var exact: u8[2] = [0xcc, 0xcc];
    let e1, x1 = honkmqtt::encode_pingresp(exact);
    assert(e1 == honkmqtt::OK && x1 == 2 && exact[0] == 0xd0 && exact[1] == 0x00);
    fill(exact, 0xcc);
    let e2, x2 = honkmqtt::encode_disconnect(exact);
    assert(e2 == honkmqtt::OK && x2 == 2 && exact[0] == 0xe0 && exact[1] == 0x00);
}

fn adjacent() {
    var buf: u8[8] = [0; 8];
    fill(buf, 0xee);
    let a, an = honkmqtt::encode_pingreq(buf);
    assert(a == honkmqtt::OK && an == 2);
    let b, bn = honkmqtt::encode_pingresp(buf[2..4]);
    assert(b == honkmqtt::OK && bn == 2);
    let c, cn = honkmqtt::encode_disconnect(buf[4..6]);
    assert(c == honkmqtt::OK && cn == 2);

    let s1, u1 = honkmqtt::pingreq(buf[0..6]);
    assert(s1 == honkmqtt::OK && u1 == 2);
    let s2, u2 = honkmqtt::pingresp(buf[2..6]);
    assert(s2 == honkmqtt::OK && u2 == 2);
    let s3, u3 = honkmqtt::disconnect(buf[4..6]);
    assert(s3 == honkmqtt::OK && u3 == 2);
    assert(buf[6] == 0xee && buf[7] == 0xee);
}

fn main() {
    literal_vectors();
    truncations();
    malformed_pingreq();
    malformed_pingresp();
    malformed_disconnect();
    encode_sentinels();
    adjacent();
    print("PINGREQ/PINGRESP/DISCONNECT tests passed");
}
