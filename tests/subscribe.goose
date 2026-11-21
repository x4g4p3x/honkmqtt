// Independent MQTT 3.1.1 SUBSCRIBE / SUBACK wire vectors
// (OASIS §§1.5.3, 2.2–2.3.1, 3.8–3.9, 4.7).
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn eq_bytes(got: const u8[:], expect: const u8[:]) {
    assert(got.len >= expect.len);
    for i in expect.len { assert(got[i] == expect[i]); }
}

fn parse_sub_fail(input: const u8[:], max_body: i64, expected: i64) {
    let st, used, id, lo, ll = honkmqtt::subscribe(input, max_body);
    assert(st == expected && used == 0 && id == 0 && lo == 0 && ll == 0);
}

fn parse_ack_fail(input: const u8[:], max_body: i64, expected: i64) {
    let st, used, id, co, cl = honkmqtt::suback(input, max_body);
    assert(st == expected && used == 0 && id == 0 && co == 0 && cl == 0);
}

fn encode_sub_fail(packet_id: i64, list: const u8[:], out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_subscribe(packet_id, list, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn encode_ack_fail(packet_id: i64, codes: const u8[:], out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_suback(packet_id, codes, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn walk_subscribe(input: const u8[:], list_off: i64, list_len: i64, expect_n: i64) {
    var pos = list_off;
    let end = list_off + list_len;
    var n = 0;
    while pos < end {
        let st, next, _, _, _ = honkmqtt::subscribe_next(input, pos, end);
        assert(st == honkmqtt::OK);
        pos = next;
        n += 1;
    }
    assert(pos == end && n == expect_n);
}

fn subscribe_vector_ok(expect: const u8[:], packet_id: i64, list: const u8[:], entries: i64) {
    let st, used, id, lo, ll = honkmqtt::subscribe(expect, 65535);
    assert(st == honkmqtt::OK && used == expect.len && id == packet_id);
    assert(ll == list.len);
    for i in list.len { assert(expect[lo + i] == list[i]); }
    walk_subscribe(expect, lo, ll, entries);

    var with_trail: u8[64] = [0; 64];
    assert(expect.len + 1 <= with_trail.len);
    for i in expect.len { with_trail[i] = expect[i]; }
    with_trail[expect.len] = 0xc0;
    let st2, used2, id2, _, _ = honkmqtt::subscribe(with_trail[0..expect.len + 1], 65535);
    assert(st2 == honkmqtt::OK && used2 == expect.len && id2 == packet_id);

    var out: u8[64] = [0; 64];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_subscribe(packet_id, list, out);
    assert(es == honkmqtt::OK && en == expect.len);
    eq_bytes(out, expect);
    for i in expect.len..out.len { assert(out[i] == 0xa5); }
}

fn suback_vector_ok(expect: const u8[:], packet_id: i64, codes: const u8[:]) {
    let st, used, id, co, cl = honkmqtt::suback(expect, 65535);
    assert(st == honkmqtt::OK && used == expect.len && id == packet_id);
    assert(cl == codes.len);
    for i in codes.len { assert(expect[co + i] == codes[i]); }

    var with_trail: u8[32] = [0; 32];
    assert(expect.len + 1 <= with_trail.len);
    for i in expect.len { with_trail[i] = expect[i]; }
    with_trail[expect.len] = 0xc0;
    let st2, used2, id2, _, _ = honkmqtt::suback(with_trail[0..expect.len + 1], 65535);
    assert(st2 == honkmqtt::OK && used2 == expect.len && id2 == packet_id);

    var out: u8[32] = [0; 32];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_suback(packet_id, codes, out);
    assert(es == honkmqtt::OK && en == expect.len);
    eq_bytes(out, expect);
    for i in expect.len..out.len { assert(out[i] == 0xa5); }
}

fn literal_subscribe() {
    // Single filter "a" QoS 0, Packet Identifier 1.
    // RL = 2 + 2+1+1 = 6.
    let list1: u8[4] = [0x00, 0x01, 0x61, 0x00];
    let v1:    u8[8] = [0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00];
    subscribe_vector_ok(v1, 1, list1, 1);

    // Two filters: "a/b" QoS1, "c/d" QoS2 (spec non-normative), id 10.
    // RL = 2 + (2+3+1) + (2+3+1) = 14 = 0x0e.
    let list2: u8[12] = [
        0x00, 0x03, 0x61, 0x2f, 0x62, 0x01,
        0x00, 0x03, 0x63, 0x2f, 0x64, 0x02,
    ];
    let v2: u8[16] = [
        0x82, 0x0e, 0x00, 0x0a,
        0x00, 0x03, 0x61, 0x2f, 0x62, 0x01,
        0x00, 0x03, 0x63, 0x2f, 0x64, 0x02,
    ];
    subscribe_vector_ok(v2, 10, list2, 2);

    // Wildcard filters and duplicate filter structurally OK.
    // RL = 2 + 4+4+4 = 14.
    let list3: u8[12] = [
        0x00, 0x01, 0x2b, 0x00,
        0x00, 0x01, 0x23, 0x02,
        0x00, 0x01, 0x2b, 0x01,
    ];
    let v3: u8[16] = [
        0x82, 0x0e, 0x00, 0x02,
        0x00, 0x01, 0x2b, 0x00,
        0x00, 0x01, 0x23, 0x02,
        0x00, 0x01, 0x2b, 0x01,
    ];
    subscribe_vector_ok(v3, 2, list3, 3);

    // Packet Identifier 0xffff.
    let list_maxid: u8[4] = [0x00, 0x01, 0x61, 0x00];
    let vmax:       u8[8] = [0x82, 0x06, 0xff, 0xff, 0x00, 0x01, 0x61, 0x00];
    subscribe_vector_ok(vmax, 65535, list_maxid, 1);
}

fn literal_suback() {
    let c1: u8[1] = [0x00];
    let a1: u8[5] = [0x90, 0x03, 0x00, 0x01, 0x00];
    suback_vector_ok(a1, 1, c1);

    // Spec non-normative: QoS0, QoS2, Failure; id 10.
    let c2: u8[3] = [0x00, 0x02, 0x80];
    let a2: u8[7] = [0x90, 0x05, 0x00, 0x0a, 0x00, 0x02, 0x80];
    suback_vector_ok(a2, 10, c2);

    let c3: u8[4] = [0x00, 0x01, 0x02, 0x80];
    let a3: u8[8] = [0x90, 0x06, 0x00, 0xff, 0x00, 0x01, 0x02, 0x80];
    suback_vector_ok(a3, 255, c3);

    // Packet Identifier 0xffff.
    let cmax: u8[1] = [0x02];
    let amax: u8[5] = [0x90, 0x03, 0xff, 0xff, 0x02];
    suback_vector_ok(amax, 65535, cmax);
}

fn truncations() {
    let sub: u8[8] = [0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00];
    parse_sub_fail("", 65535, honkmqtt::INCOMPLETE);
    parse_sub_fail(sub[0..1], 65535, honkmqtt::INCOMPLETE);
    parse_sub_fail(sub[0..2], 65535, honkmqtt::INCOMPLETE);
    parse_sub_fail(sub[0..4], 65535, honkmqtt::INCOMPLETE);
    parse_sub_fail(sub[0..7], 65535, honkmqtt::INCOMPLETE);

    let ack: u8[5] = [0x90, 0x03, 0x00, 0x01, 0x00];
    parse_ack_fail("", 65535, honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..1], 65535, honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..2], 65535, honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..4], 65535, honkmqtt::INCOMPLETE);
}

fn malformed_subscribe() {
    // Wrong fixed-header flags / type (PUBLISH-shaped body isolates type).
    parse_sub_fail([0x80, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00], 65535, honkmqtt::INVALID);
    parse_sub_fail([0x30, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00], 65535, honkmqtt::INVALID);

    // RL below minimum (header-only) → INVALID, not INCOMPLETE.
    parse_sub_fail([0x82, 0x05], 65535, honkmqtt::INVALID);
    parse_sub_fail([0x82, 0x00], 65535, honkmqtt::INVALID);

    // Zero Packet Identifier.
    parse_sub_fail([0x82, 0x06, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00], 65535, honkmqtt::INVALID);

    // Empty list: RL == 2 (id only) is below min 6 → INVALID at RL bound.
    parse_sub_fail([0x82, 0x02, 0x00, 0x01], 65535, honkmqtt::INVALID);

    // Reserved QoS bits / QoS 3 (otherwise valid single entry).
    parse_sub_fail([0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x03], 65535, honkmqtt::INVALID);
    parse_sub_fail([0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x80], 65535, honkmqtt::INVALID);

    // Empty filter (paired with a second valid entry so RL ≥ 6 isolates the cause).
    parse_sub_fail([0x82, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00], 65535, honkmqtt::INVALID);
    // Invalid UTF-8 / U+0000 in filter.
    parse_sub_fail([0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Invalid wildcard placement ("a+") with otherwise correct RL — pins valid_filter.
    parse_sub_fail([0x82, 0x07, 0x00, 0x01, 0x00, 0x02, 0x61, 0x2b, 0x00], 65535, honkmqtt::INVALID);

    // Length past Remaining Length (complete frame → INVALID).
    parse_sub_fail([0x82, 0x06, 0x00, 0x01, 0x00, 0x05, 0x61, 0x00], 65535, honkmqtt::INVALID);

    // Trailing junk after a complete entry inside RL.
    parse_sub_fail([0x82, 0x07, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00, 0xff], 65535, honkmqtt::INVALID);

    // Missing QoS byte after filter (RL 6 ends at filter data for "ab").
    parse_sub_fail([0x82, 0x06, 0x00, 0x01, 0x00, 0x02, 0x61, 0x62], 65535, honkmqtt::INVALID);

    // max_body / negative.
    let good: u8[8] = [0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00];
    parse_sub_fail(good, 5, honkmqtt::INVALID);
    parse_sub_fail(good, -1, honkmqtt::INVALID);

    // Non-minimal Remaining Length.
    parse_sub_fail([0x82, 0x86, 0x00, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00], 65535, honkmqtt::INVALID);

    var out: u8[32] = [0; 32];
    encode_sub_fail(0, [0x00, 0x01, 0x61, 0x00], out, honkmqtt::INVALID);
    encode_sub_fail(65536, [0x00, 0x01, 0x61, 0x00], out, honkmqtt::INVALID);
    encode_sub_fail(1, "", out, honkmqtt::INVALID);
    encode_sub_fail(1, [0x00, 0x01, 0x61, 0x03], out, honkmqtt::INVALID);
    encode_sub_fail(1, [0x00, 0x00, 0x00], out, honkmqtt::INVALID);
    var tiny: u8[4] = [0; 4];
    encode_sub_fail(1, [0x00, 0x01, 0x61, 0x00], tiny, honkmqtt::NO_SPACE);
    encode_sub_fail(0, [0x00, 0x01, 0x61, 0x00], tiny, honkmqtt::INVALID);
}

fn malformed_suback() {
    // Wrong flags / type with otherwise valid SUBACK body.
    parse_ack_fail([0x91, 0x03, 0x00, 0x01, 0x00], 65535, honkmqtt::INVALID);
    parse_ack_fail([0x82, 0x03, 0x00, 0x01, 0x00], 65535, honkmqtt::INVALID);

    // RL below minimum.
    parse_ack_fail([0x90, 0x02], 65535, honkmqtt::INVALID);
    parse_ack_fail([0x90, 0x00], 65535, honkmqtt::INVALID);

    // Zero Packet Identifier.
    parse_ack_fail([0x90, 0x03, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Reserved return codes.
    parse_ack_fail([0x90, 0x03, 0x00, 0x01, 0x03], 65535, honkmqtt::INVALID);
    parse_ack_fail([0x90, 0x03, 0x00, 0x01, 0x7f], 65535, honkmqtt::INVALID);
    parse_ack_fail([0x90, 0x03, 0x00, 0x01, 0x81], 65535, honkmqtt::INVALID);

    let good: u8[5] = [0x90, 0x03, 0x00, 0x01, 0x00];
    parse_ack_fail(good, 2, honkmqtt::INVALID);
    parse_ack_fail(good, -1, honkmqtt::INVALID);

    var out: u8[16] = [0; 16];
    encode_ack_fail(0, [0x00], out, honkmqtt::INVALID);
    encode_ack_fail(1, "", out, honkmqtt::INVALID);
    encode_ack_fail(1, [0x03], out, honkmqtt::INVALID);
    var tiny: u8[2] = [0; 2];
    encode_ack_fail(1, [0x00], tiny, honkmqtt::NO_SPACE);
    encode_ack_fail(0, [0x00], tiny, honkmqtt::INVALID);
}

fn subscribe_next_bounds() {
    let pkt: u8[8] = [0x82, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0x00];
    let st, used, _, lo, ll = honkmqtt::subscribe(pkt, 64);
    assert(st == honkmqtt::OK && used == 8);
    let end = lo + ll;

    // Direct iterator ABI: malformed cursor / boundary cases.
    let e1, _, _, _, _ = honkmqtt::subscribe_next(pkt, end, end);
    assert(e1 == honkmqtt::INVALID);
    let e2, _, _, _, _ = honkmqtt::subscribe_next(pkt, end + 1, end);
    assert(e2 == honkmqtt::INVALID);
    let e3, _, _, _, _ = honkmqtt::subscribe_next(pkt, -1, end);
    assert(e3 == honkmqtt::INVALID);
    let e4, _, _, _, _ = honkmqtt::subscribe_next(pkt, lo, pkt.len + 1);
    assert(e4 == honkmqtt::INVALID);
    // Truncated mid-entry: stop before QoS byte.
    let e5, _, _, _, _ = honkmqtt::subscribe_next(pkt, lo, lo + 3);
    assert(e5 == honkmqtt::INVALID);
    // Length past iterator end.
    let e6, _, _, _, _ = honkmqtt::subscribe_next(pkt, lo, lo + 2);
    assert(e6 == honkmqtt::INVALID);
}

fn boundary_filter() {
    // 65535-byte filter accept.
    var filt: u8[65535] = ['a'; 65535];
    var list: u8[65538] = [0; 65538];
    list[0] = 0xff;
    list[1] = 0xff;
    for i in filt.len { list[2 + i] = filt[i]; }
    list[2 + 65535] = 0x01;
    var out: u8[65550] = [0; 65550];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_subscribe(1, list[0..2 + 65535 + 1], out);
    assert(es == honkmqtt::OK);
    assert(out[0] == 0x82 && out[1] == 0x84 && out[2] == 0x80 && out[3] == 0x04);
    let st, used, id, lo, ll = honkmqtt::subscribe(out[0..en], 70000);
    assert(st == honkmqtt::OK && used == en && id == 1 && ll == 2 + 65535 + 1);
    let ns, next, fo, fl, qos = honkmqtt::subscribe_next(out, lo, lo + ll);
    assert(ns == honkmqtt::OK && fl == 65535 && qos == 1 && next == lo + ll);
    assert(out[fo] == 'a' && out[fo + 65534] == 'a');

    // Two-byte length 0xFFFF with only partial data → missing-data INVALID
    // (not a 65536-byte filter; the length field cannot encode that).
    encode_sub_fail(1, [0xff, 0xff, 0x61, 0x62], out[0..8], honkmqtt::INVALID);
    // Nominal max length prefix with trailing junk after a short complete entry.
    encode_sub_fail(1, [0x00, 0x01, 0x61, 0x00, 0xff], out[0..8], honkmqtt::INVALID);
}

fn adjacent() {
    var buf: u8[32] = [0; 32];
    fill(buf, 0xee);
    let list: u8[4] = [0x00, 0x01, 0x61, 0x00];
    let es, en = honkmqtt::encode_subscribe(1, list, buf);
    assert(es == honkmqtt::OK && en == 8);
    let codes: u8[1] = [0x00];
    let as_, an = honkmqtt::encode_suback(1, codes, buf[en..en + 8]);
    assert(as_ == honkmqtt::OK && an == 5);
    let ss, su, _, _, _ = honkmqtt::subscribe(buf[0..en + an], 64);
    assert(ss == honkmqtt::OK && su == en);
    let ks, ku, _, _, _ = honkmqtt::suback(buf[en..en + an], 64);
    assert(ks == honkmqtt::OK && ku == an);
    for i in en + an..buf.len { assert(buf[i] == 0xee); }
}

fn main() {
    literal_subscribe();
    literal_suback();
    truncations();
    malformed_subscribe();
    malformed_suback();
    subscribe_next_bounds();
    boundary_filter();
    adjacent();
    print("SUBSCRIBE/SUBACK tests passed");
}
