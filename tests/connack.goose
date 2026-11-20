// Independent MQTT 3.1.1 CONNACK wire vectors (OASIS §§2.2.2–2.2.3, 3.2).
// Expected bytes are asserted before round trips.
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn eq4(got: const u8[:], expect: const u8[:]) {
    assert(got.len >= 4 && expect.len == 4);
    for i in 4 { assert(got[i] == expect[i]); }
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

// One independent 4-byte vector drives both parse and encode checks.
fn vector_ok(session: bool, code: i64, expect: const u8[:]) {
    parse_ok(session, code, expect);
    var out: u8[8] = [0; 8];
    fill(out, 0xa5);
    let st, n = honkmqtt::encode_connack(session, code, out);
    assert(st == honkmqtt::OK && n == 4);
    eq4(out, expect);
    for i in 4..out.len { assert(out[i] == 0xa5); }
}

fn encode_fail(session: bool, code: i64, out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_connack(session, code, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn literal_vectors() {
    // Accepted; Session Present clear (structural only—not a CleanSession claim).
    let a0: u8[4] = [0x20, 0x02, 0x00, 0x00];
    vector_ok(false, honkmqtt::CONNACK_ACCEPTED, a0);

    // Accepted, Session Present set.
    let a1: u8[4] = [0x20, 0x02, 0x01, 0x00];
    vector_ok(true, 0, a1);

    // Refusal codes 1..5 with Session Present clear — each has its own
    // independently specified parser+encoder vector.
    let r1: u8[4] = [0x20, 0x02, 0x00, 0x01];
    vector_ok(false, honkmqtt::CONNACK_REFUSED_PROTOCOL, r1);
    let r2: u8[4] = [0x20, 0x02, 0x00, 0x02];
    vector_ok(false, honkmqtt::CONNACK_REFUSED_IDENTIFIER, r2);
    let r3: u8[4] = [0x20, 0x02, 0x00, 0x03];
    vector_ok(false, honkmqtt::CONNACK_REFUSED_SERVER, r3);
    let r4: u8[4] = [0x20, 0x02, 0x00, 0x04];
    vector_ok(false, honkmqtt::CONNACK_REFUSED_CREDENTIALS, r4);
    let r5: u8[4] = [0x20, 0x02, 0x00, 0x05];
    vector_ok(false, honkmqtt::CONNACK_REFUSED_UNAUTHORIZED, r5);
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
    // INVALID is decided before NO_SPACE: short out + illegal fields → INVALID.
    encode_fail(true, 1, tiny, honkmqtt::INVALID);
    encode_fail(false, 6, tiny, honkmqtt::INVALID);
}

fn adjacent_and_compat() {
    var buf: u8[8] = [0; 8];
    fill(buf, 0xee);
    let es, en = honkmqtt::encode_connack(false, 0, buf);
    assert(es == honkmqtt::OK && en == 4);
    let expect: u8[4] = [0x20, 0x02, 0x00, 0x00];
    eq4(buf, expect);
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
