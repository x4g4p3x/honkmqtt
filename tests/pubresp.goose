// Independent MQTT 3.1.1 PUBACK/PUBREC/PUBREL/PUBCOMP wire vectors (OASIS
// §§2.2.2–2.2.3, 2.3.1, 3.4–3.7). Expected bytes are asserted before round trips.
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

fn first_byte(kind: i64) -> u8 {
    if kind == honkmqtt::PUBREL { return 0x62; }
    return ((kind * 16) as u8);
}

fn parse_ok(kind: i64, id: i64, expect: const u8[:]) {
    assert(expect.len == 4);
    let st, used, got = honkmqtt::pubresp(expect, kind);
    assert(st == honkmqtt::OK && used == 4 && got == id);
    // Trailing byte after a complete packet must remain unconsumed.
    var with_trail: u8[5] = [0; 5];
    for i in 4 { with_trail[i] = expect[i]; }
    with_trail[4] = 0xc0;
    let st2, used2, id2 = honkmqtt::pubresp(with_trail, kind);
    assert(st2 == honkmqtt::OK && used2 == 4 && id2 == id);
}

fn parse_fail(input: const u8[:], kind: i64, expected: i64) {
    let st, used, id = honkmqtt::pubresp(input, kind);
    assert(st == expected && used == 0 && id == 0);
}

fn encode_ok(kind: i64, id: i64, a: u8, b: u8, c: u8, d: u8) {
    var out: u8[8] = [0; 8];
    fill(out, 0xa5);
    let st, n = honkmqtt::encode_pubresp(kind, id, out);
    assert(st == honkmqtt::OK && n == 4);
    eq4(out, a, b, c, d);
    for i in 4..out.len { assert(out[i] == 0xa5); }
    // Round trip supplements the independent vector.
    let ps, used, got = honkmqtt::pubresp(out[0..n], kind);
    assert(ps == honkmqtt::OK && used == n && got == id);
}

fn encode_fail(kind: i64, id: i64, out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_pubresp(kind, id, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn literal_vectors() {
    // Independent literals: type/flags, Remaining Length 0x02, big-endian id.
    // PUBACK id=1
    let ack1: u8[4] = [0x40, 0x02, 0x00, 0x01];
    parse_ok(honkmqtt::PUBACK, 1, ack1);
    encode_ok(honkmqtt::PUBACK, 1, 0x40, 0x02, 0x00, 0x01);

    // PUBREC id=0x1234
    let rec: u8[4] = [0x50, 0x02, 0x12, 0x34];
    parse_ok(honkmqtt::PUBREC, 0x1234, rec);
    encode_ok(honkmqtt::PUBREC, 0x1234, 0x50, 0x02, 0x12, 0x34);

    // PUBREL id=0x00ff (flags must be 0b0010 → 0x62)
    let rel: u8[4] = [0x62, 0x02, 0x00, 0xff];
    parse_ok(honkmqtt::PUBREL, 0x00ff, rel);
    encode_ok(honkmqtt::PUBREL, 0x00ff, 0x62, 0x02, 0x00, 0xff);

    // PUBCOMP id=0xffff
    let comp: u8[4] = [0x70, 0x02, 0xff, 0xff];
    parse_ok(honkmqtt::PUBCOMP, 65535, comp);
    encode_ok(honkmqtt::PUBCOMP, 65535, 0x70, 0x02, 0xff, 0xff);

    // Endian / boundary ids for PUBACK
    encode_ok(honkmqtt::PUBACK, 256, 0x40, 0x02, 0x01, 0x00);
    encode_ok(honkmqtt::PUBACK, 257, 0x40, 0x02, 0x01, 0x01);
}

fn truncations() {
    // Every proper prefix of a valid 4-byte packet is INCOMPLETE, consume 0.
    let kinds: i64[4] = [
        honkmqtt::PUBACK, honkmqtt::PUBREC, honkmqtt::PUBREL, honkmqtt::PUBCOMP,
    ];
    for k in 4 {
        let kind = kinds[k];
        var pkt: u8[4] = [0; 4];
        pkt[0] = first_byte(kind);
        pkt[1] = 2;
        pkt[2] = 0x12;
        pkt[3] = 0x34;
        parse_fail("", kind, honkmqtt::INCOMPLETE);
        parse_fail(pkt[0..1], kind, honkmqtt::INCOMPLETE);
        parse_fail(pkt[0..2], kind, honkmqtt::INCOMPLETE);
        parse_fail(pkt[0..3], kind, honkmqtt::INCOMPLETE);
        parse_ok(kind, 0x1234, pkt);
    }
}

fn malformed() {
    // Bad kind argument.
    parse_fail([0x40, 0x02, 0x00, 0x01], 3, honkmqtt::INVALID);
    parse_fail([0x40, 0x02, 0x00, 0x01], 8, honkmqtt::INVALID);
    var out: u8[4] = [0; 4];
    encode_fail(3, 1, out, honkmqtt::INVALID);
    encode_fail(0, 1, out, honkmqtt::INVALID);

    // Wrong flags (PUBACK/PUBREC/PUBCOMP require 0; PUBREL requires 2).
    parse_fail([0x41, 0x02, 0x00, 0x01], honkmqtt::PUBACK, honkmqtt::INVALID);
    parse_fail([0x52, 0x02, 0x00, 0x01], honkmqtt::PUBREC, honkmqtt::INVALID);
    parse_fail([0x60, 0x02, 0x00, 0x01], honkmqtt::PUBREL, honkmqtt::INVALID);
    parse_fail([0x63, 0x02, 0x00, 0x01], honkmqtt::PUBREL, honkmqtt::INVALID);
    parse_fail([0x71, 0x02, 0x00, 0x01], honkmqtt::PUBCOMP, honkmqtt::INVALID);

    // Type mismatch: well-formed PUBREC offered as PUBACK.
    parse_fail([0x50, 0x02, 0x00, 0x01], honkmqtt::PUBACK, honkmqtt::INVALID);
    // Unrecognized / other MQTT type.
    parse_fail([0x30, 0x02, 0x00, 0x01], honkmqtt::PUBACK, honkmqtt::INVALID);
    parse_fail([0xc0, 0x00], honkmqtt::PUBACK, honkmqtt::INVALID);

    // Wrong Remaining Length value (not 2).
    parse_fail([0x40, 0x00], honkmqtt::PUBACK, honkmqtt::INVALID);
    parse_fail([0x40, 0x01, 0x00], honkmqtt::PUBACK, honkmqtt::INVALID);
    parse_fail([0x40, 0x03, 0x00, 0x01, 0x00], honkmqtt::PUBACK, honkmqtt::INVALID);
    // Non-minimal Remaining Length for value 2.
    parse_fail([0x40, 0x82, 0x00, 0x00, 0x01], honkmqtt::PUBACK, honkmqtt::INVALID);

    // Zero Packet Identifier.
    parse_fail([0x40, 0x02, 0x00, 0x00], honkmqtt::PUBACK, honkmqtt::INVALID);
    parse_fail([0x62, 0x02, 0x00, 0x00], honkmqtt::PUBREL, honkmqtt::INVALID);

    // Encode: invalid / zero / oversize id; NO_SPACE; full sentinel preserved.
    encode_fail(honkmqtt::PUBACK, 0, out, honkmqtt::INVALID);
    encode_fail(honkmqtt::PUBACK, -1, out, honkmqtt::INVALID);
    encode_fail(honkmqtt::PUBACK, 65536, out, honkmqtt::INVALID);
    var tiny: u8[3] = [0; 3];
    encode_fail(honkmqtt::PUBREC, 1, tiny, honkmqtt::NO_SPACE);
    var empty: u8[0] = [];
    // Zero-length out: NO_SPACE with nothing to scribble.
    let st, n = honkmqtt::encode_pubresp(honkmqtt::PUBCOMP, 1, empty);
    assert(st == honkmqtt::NO_SPACE && n == 0);
}

fn adjacent_and_compat() {
    // PUBACK then PINGREQ in one buffer; trailing frame left for the caller.
    var buf: u8[8] = [0; 8];
    fill(buf, 0xee);
    let es, en = honkmqtt::encode_pubresp(honkmqtt::PUBACK, 7, buf);
    assert(es == honkmqtt::OK && en == 4);
    eq4(buf, 0x40, 0x02, 0x00, 0x07);
    let ps, pn = honkmqtt::encode(0xc0, "", buf[4..6]);
    assert(ps == honkmqtt::OK && pn == 2);
    assert(buf[4] == 0xc0 && buf[5] == 0);
    for i in 6..buf.len { assert(buf[i] == 0xee); }
    let ok, used, id = honkmqtt::pubresp(buf[0..6], honkmqtt::PUBACK);
    assert(ok == honkmqtt::OK && used == 4 && id == 7);
    let fs, fu = honkmqtt::frame(buf[4..6], 0);
    assert(fs == honkmqtt::OK && fu == 2);
    // Opaque encode still frames a PUBREL-shaped first byte without body checks.
    var opaque: u8[4] = [0; 4];
    let os, on = honkmqtt::encode(0x62, [0x00, 0x01], opaque);
    assert(os == honkmqtt::OK && on == 4);
}

fn main() {
    literal_vectors();
    truncations();
    malformed();
    adjacent_and_compat();
    print("PUBACK family tests passed");
}
