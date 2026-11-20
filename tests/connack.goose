// Independent MQTT 3.1.1 CONNACK wire vectors (OASIS §§2.2.2–2.2.3, 3.2).
// Expected bytes are asserted before round trips.
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn eq4(got: const u8[:], a: u8, b: u8, c: u8, d: u8) {
    assert(got.len >= 4);
    assert(got[0] == a && got[1] == b && got[2] == c && got[3] == d);
}

fn parse_ok(session: bool, code: i64, expect: const u8[:]) {
    assert(expect.len == 4);
    let st, used, sp, rc = honkmqtt::connack(expect);
    assert(st == honkmqtt::OK && used == 4 && sp == session && rc == code);
    var with_trail: u8[5] = [0; 5];
    for i in 4 { with_trail[i] = expect[i]; }
    with_trail[4] = 0xc0;
    let st2, used2, sp2, rc2 = honkmqtt::connack(with_trail);
    assert(st2 == honkmqtt::OK && used2 == 4 && sp2 == session && rc2 == code);
}

fn parse_fail(input: const u8[:], expected: i64) {
    let st, used, sp, rc = honkmqtt::connack(input);
    assert(st == expected && used == 0 && sp == false && rc == 0);
}

fn encode_ok(session: bool, code: i64, a: u8, b: u8, c: u8, d: u8) {
    var out: u8[8] = [0; 8];
    fill(out, 0xa5);
    let st, n = honkmqtt::encode_connack(session, code, out);
    assert(st == honkmqtt::OK && n == 4);
    eq4(out, a, b, c, d);
    for i in 4..out.len { assert(out[i] == 0xa5); }
    let ps, used, sp, rc = honkmqtt::connack(out[0..n]);
    assert(ps == honkmqtt::OK && used == n && sp == session && rc == code);
}

fn encode_fail(session: bool, code: i64, out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_connack(session, code, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn literal_vectors() {
    // Accepted, clean session.
    let a0: u8[4] = [0x20, 0x02, 0x00, 0x00];
    parse_ok(false, honkmqtt::CONNACK_ACCEPTED, a0);
    encode_ok(false, 0, 0x20, 0x02, 0x00, 0x00);

    // Accepted, Session Present.
    let a1: u8[4] = [0x20, 0x02, 0x01, 0x00];
    parse_ok(true, 0, a1);
    encode_ok(true, 0, 0x20, 0x02, 0x01, 0x00);

    // Refusal codes 1..5 with Session Present clear.
    encode_ok(false, 1, 0x20, 0x02, 0x00, 0x01);
    encode_ok(false, 2, 0x20, 0x02, 0x00, 0x02);
    encode_ok(false, 3, 0x20, 0x02, 0x00, 0x03);
    encode_ok(false, 4, 0x20, 0x02, 0x00, 0x04);
    encode_ok(false, 5, 0x20, 0x02, 0x00, 0x05);
    let r5: u8[4] = [0x20, 0x02, 0x00, 0x05];
    parse_ok(false, honkmqtt::CONNACK_REFUSED_UNAUTHORIZED, r5);
}

fn truncations() {
    let pkt: u8[4] = [0x20, 0x02, 0x00, 0x00];
    parse_fail("", honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..1], honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..2], honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..3], honkmqtt::INCOMPLETE);
    parse_ok(false, 0, pkt);
}

fn malformed() {
    // Wrong fixed-header flags / type.
    parse_fail([0x21, 0x02, 0x00, 0x00], honkmqtt::INVALID);
    parse_fail([0x30, 0x02, 0x00, 0x00], honkmqtt::INVALID);
    parse_fail([0x40, 0x02, 0x00, 0x01], honkmqtt::INVALID);

    // Wrong Remaining Length (complete header with RL≠2 is INVALID before body).
    parse_fail([0x20, 0x00], honkmqtt::INVALID);
    parse_fail([0x20, 0x01, 0x00], honkmqtt::INVALID);
    parse_fail([0x20, 0x03], honkmqtt::INVALID);
    parse_fail([0x20, 0x03, 0x00, 0x00, 0x00], honkmqtt::INVALID);
    parse_fail([0x20, 0x82, 0x00, 0x00, 0x00], honkmqtt::INVALID);

    // Reserved acknowledge flag bits.
    parse_fail([0x20, 0x02, 0x02, 0x00], honkmqtt::INVALID);
    parse_fail([0x20, 0x02, 0x80, 0x00], honkmqtt::INVALID);
    parse_fail([0x20, 0x02, 0x03, 0x00], honkmqtt::INVALID);

    // Reserved return codes 6..255.
    parse_fail([0x20, 0x02, 0x00, 0x06], honkmqtt::INVALID);
    parse_fail([0x20, 0x02, 0x00, 0xff], honkmqtt::INVALID);

    // Session Present with non-zero return code.
    parse_fail([0x20, 0x02, 0x01, 0x01], honkmqtt::INVALID);
    parse_fail([0x20, 0x02, 0x01, 0x05], honkmqtt::INVALID);

    var out: u8[4] = [0; 4];
    encode_fail(false, -1, out, honkmqtt::INVALID);
    encode_fail(false, 6, out, honkmqtt::INVALID);
    encode_fail(false, 256, out, honkmqtt::INVALID);
    encode_fail(true, 1, out, honkmqtt::INVALID);
    encode_fail(true, 5, out, honkmqtt::INVALID);
    var tiny: u8[3] = [0; 3];
    encode_fail(false, 0, tiny, honkmqtt::NO_SPACE);
}

fn adjacent_and_compat() {
    var buf: u8[8] = [0; 8];
    fill(buf, 0xee);
    let es, en = honkmqtt::encode_connack(false, 0, buf);
    assert(es == honkmqtt::OK && en == 4);
    eq4(buf, 0x20, 0x02, 0x00, 0x00);
    let ps, pn = honkmqtt::encode(0xc0, "", buf[4..6]);
    assert(ps == honkmqtt::OK && pn == 2);
    assert(buf[4] == 0xc0 && buf[5] == 0);
    for i in 6..buf.len { assert(buf[i] == 0xee); }
    let ok, used, sp, rc = honkmqtt::connack(buf[0..6]);
    assert(ok == honkmqtt::OK && used == 4 && sp == false && rc == 0);
    let fs, fu = honkmqtt::frame(buf[4..6], 0);
    assert(fs == honkmqtt::OK && fu == 2);
}

fn main() {
    literal_vectors();
    truncations();
    malformed();
    adjacent_and_compat();
    print("CONNACK tests passed");
}
