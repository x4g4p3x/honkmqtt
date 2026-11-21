// Independent MQTT 3.1.1 UNSUBSCRIBE / UNSUBACK wire vectors
// (OASIS §§1.5.3, 2.2–2.3.1, 3.10–3.11, 4.7).
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

fn parse_unsub_fail(input: const u8[:], max_body: i64, expected: i64) {
    let st, used, id, lo, ll = honkmqtt::unsubscribe(input, max_body);
    assert(st == expected && used == 0 && id == 0 && lo == 0 && ll == 0);
}

fn parse_ack_fail(input: const u8[:], expected: i64) {
    let st, used, id = honkmqtt::unsuback(input);
    assert(st == expected && used == 0 && id == 0);
}

fn encode_unsub_fail(packet_id: i64, list: const u8[:], out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_unsubscribe(packet_id, list, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn encode_ack_fail(packet_id: i64, out: u8[:], expected: i64) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_unsuback(packet_id, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn walk_unsubscribe(input: const u8[:], list_off: i64, list_len: i64, expect_n: i64) {
    var pos = list_off;
    let end = list_off + list_len;
    var n = 0;
    while pos < end {
        let st, next, _, _ = honkmqtt::unsubscribe_next(input, pos, end);
        assert(st == honkmqtt::OK);
        pos = next;
        n += 1;
    }
    assert(pos == end && n == expect_n);
}

fn unsubscribe_vector_ok(expect: const u8[:], packet_id: i64, list: const u8[:], entries: i64) {
    let st, used, id, lo, ll = honkmqtt::unsubscribe(expect, 65535);
    assert(st == honkmqtt::OK && used == expect.len && id == packet_id);
    assert(ll == list.len);
    for i in list.len { assert(expect[lo + i] == list[i]); }
    walk_unsubscribe(expect, lo, ll, entries);

    var with_trail: u8[64] = [0; 64];
    assert(expect.len + 1 <= with_trail.len);
    for i in expect.len { with_trail[i] = expect[i]; }
    with_trail[expect.len] = 0xc0;
    let st2, used2, id2, _, _ = honkmqtt::unsubscribe(with_trail[0..expect.len + 1], 65535);
    assert(st2 == honkmqtt::OK && used2 == expect.len && id2 == packet_id);

    var out: u8[64] = [0; 64];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_unsubscribe(packet_id, list, out);
    assert(es == honkmqtt::OK && en == expect.len);
    eq_bytes(out, expect);
    for i in expect.len..out.len { assert(out[i] == 0xa5); }
}

fn unsuback_vector_ok(expect: const u8[:], packet_id: i64) {
    let st, used, id = honkmqtt::unsuback(expect);
    assert(st == honkmqtt::OK && used == expect.len && id == packet_id);

    var with_trail: u8[8] = [0; 8];
    assert(expect.len + 1 <= with_trail.len);
    for i in expect.len { with_trail[i] = expect[i]; }
    with_trail[expect.len] = 0xc0;
    let st2, used2, id2 = honkmqtt::unsuback(with_trail[0..expect.len + 1]);
    assert(st2 == honkmqtt::OK && used2 == expect.len && id2 == packet_id);

    var out: u8[8] = [0; 8];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_unsuback(packet_id, out);
    assert(es == honkmqtt::OK && en == expect.len);
    eq_bytes(out, expect);
    for i in expect.len..out.len { assert(out[i] == 0xa5); }
}

fn literal_unsubscribe() {
    // Single filter "a", Packet Identifier 1.
    // RL = 2 + 2+1 = 5.
    let list1: u8[3] = [0x00, 0x01, 0x61];
    let v1:    u8[7] = [0xa2, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61];
    unsubscribe_vector_ok(v1, 1, list1, 1);

    // Two filters: "a/b", "c/d" (spec non-normative layout, no QoS), id 10.
    // RL = 2 + (2+3) + (2+3) = 12 = 0x0c.
    let list2: u8[10] = [
        0x00, 0x03, 0x61, 0x2f, 0x62,
        0x00, 0x03, 0x63, 0x2f, 0x64,
    ];
    let v2: u8[14] = [
        0xa2, 0x0c, 0x00, 0x0a,
        0x00, 0x03, 0x61, 0x2f, 0x62,
        0x00, 0x03, 0x63, 0x2f, 0x64,
    ];
    unsubscribe_vector_ok(v2, 10, list2, 2);

    // Wildcard filters and duplicate filter structurally OK; order preserved.
    // RL = 2 + 3+3+3 = 11.
    let list3: u8[9] = [
        0x00, 0x01, 0x2b,
        0x00, 0x01, 0x23,
        0x00, 0x01, 0x2b,
    ];
    let v3: u8[13] = [
        0xa2, 0x0b, 0x00, 0x02,
        0x00, 0x01, 0x2b,
        0x00, 0x01, 0x23,
        0x00, 0x01, 0x2b,
    ];
    unsubscribe_vector_ok(v3, 2, list3, 3);

    // Multi-byte UTF-8 filter "€" (U+20AC = e2 82 ac), id 7.
    // RL = 2 + 2+3 = 7.
    let list_utf: u8[5] = [0x00, 0x03, 0xe2, 0x82, 0xac];
    let v_utf:    u8[9] = [0xa2, 0x07, 0x00, 0x07, 0x00, 0x03, 0xe2, 0x82, 0xac];
    unsubscribe_vector_ok(v_utf, 7, list_utf, 1);

    // Packet Identifier 0xffff.
    let list_maxid: u8[3] = [0x00, 0x01, 0x61];
    let vmax:       u8[7] = [0xa2, 0x05, 0xff, 0xff, 0x00, 0x01, 0x61];
    unsubscribe_vector_ok(vmax, 65535, list_maxid, 1);
}

fn literal_unsuback() {
    let a1: u8[4] = [0xb0, 0x02, 0x00, 0x01];
    unsuback_vector_ok(a1, 1);

    let a2: u8[4] = [0xb0, 0x02, 0x00, 0x0a];
    unsuback_vector_ok(a2, 10);

    let amax: u8[4] = [0xb0, 0x02, 0xff, 0xff];
    unsuback_vector_ok(amax, 65535);
}

fn truncations() {
    let unsub: u8[7] = [0xa2, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61];
    parse_unsub_fail("", 65535, honkmqtt::INCOMPLETE);
    parse_unsub_fail(unsub[0..1], 65535, honkmqtt::INCOMPLETE);
    parse_unsub_fail(unsub[0..2], 65535, honkmqtt::INCOMPLETE);
    parse_unsub_fail(unsub[0..4], 65535, honkmqtt::INCOMPLETE);
    parse_unsub_fail(unsub[0..6], 65535, honkmqtt::INCOMPLETE);

    let ack: u8[4] = [0xb0, 0x02, 0x00, 0x01];
    parse_ack_fail("", honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..1], honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..2], honkmqtt::INCOMPLETE);
    parse_ack_fail(ack[0..3], honkmqtt::INCOMPLETE);
}

fn malformed_unsubscribe() {
    // Wrong fixed-header flags / type (PUBLISH-shaped body isolates type).
    parse_unsub_fail([0xa0, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);
    parse_unsub_fail([0x30, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);

    // RL below minimum (header-only) → INVALID, not INCOMPLETE.
    parse_unsub_fail([0xa2, 0x04], 65535, honkmqtt::INVALID);
    parse_unsub_fail([0xa2, 0x00], 65535, honkmqtt::INVALID);

    // Zero Packet Identifier.
    parse_unsub_fail([0xa2, 0x05, 0x00, 0x00, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);

    // Empty list: RL == 2 (id only) is below min 5 → INVALID at RL bound.
    parse_unsub_fail([0xa2, 0x02, 0x00, 0x01], 65535, honkmqtt::INVALID);

    // Empty filter (paired with a second valid entry so RL ≥ 5 isolates the cause).
    parse_unsub_fail([0xa2, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);
    // Invalid UTF-8 / U+0000 in filter.
    parse_unsub_fail([0xa2, 0x05, 0x00, 0x01, 0x00, 0x01, 0x00], 65535, honkmqtt::INVALID);

    // Invalid wildcard placement ("a+") with otherwise correct RL — pins valid_filter.
    parse_unsub_fail([0xa2, 0x06, 0x00, 0x01, 0x00, 0x02, 0x61, 0x2b], 65535, honkmqtt::INVALID);

    // Length past Remaining Length (complete frame → INVALID).
    parse_unsub_fail([0xa2, 0x05, 0x00, 0x01, 0x00, 0x05, 0x61], 65535, honkmqtt::INVALID);

    // Complete UNSUBSCRIBE whose final filter length runs one byte past RL,
    // followed by a literal QoS-0 PUBLISH [30 03 00 01 62]. The next-frame
    // first byte 0x30 is ASCII '0' (valid filter data), so an overread cannot
    // be rejected via invalid UTF-8—list validation must stop at the declared
    // Remaining Length and return INVALID with zero outputs.
    parse_unsub_fail([
        0xa2, 0x05, 0x00, 0x01, 0x00, 0x02, 0x61,
        0x30, 0x03, 0x00, 0x01, 0x62,
    ], 65535, honkmqtt::INVALID);

    // Trailing junk after a complete entry inside RL.
    parse_unsub_fail([0xa2, 0x06, 0x00, 0x01, 0x00, 0x01, 0x61, 0xff], 65535, honkmqtt::INVALID);

    // max_body / negative.
    let good: u8[7] = [0xa2, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61];
    parse_unsub_fail(good, 4, honkmqtt::INVALID);
    parse_unsub_fail(good, -1, honkmqtt::INVALID);

    // Non-minimal Remaining Length.
    parse_unsub_fail([0xa2, 0x85, 0x00, 0x00, 0x01, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);

    var out: u8[32] = [0; 32];
    encode_unsub_fail(0, [0x00, 0x01, 0x61], out, honkmqtt::INVALID);
    encode_unsub_fail(65536, [0x00, 0x01, 0x61], out, honkmqtt::INVALID);
    encode_unsub_fail(1, "", out, honkmqtt::INVALID);
    encode_unsub_fail(1, [0x00, 0x00], out, honkmqtt::INVALID);
    encode_unsub_fail(1, [0x00, 0x02, 0x61, 0x2b], out, honkmqtt::INVALID);
    var tiny: u8[4] = [0; 4];
    encode_unsub_fail(1, [0x00, 0x01, 0x61], tiny, honkmqtt::NO_SPACE);
    encode_unsub_fail(0, [0x00, 0x01, 0x61], tiny, honkmqtt::INVALID);
}

fn malformed_unsuback() {
    // Wrong flags / type with otherwise valid UNSUBACK body.
    parse_ack_fail([0xb1, 0x02, 0x00, 0x01], honkmqtt::INVALID);
    parse_ack_fail([0xa2, 0x02, 0x00, 0x01], honkmqtt::INVALID);

    // Remaining Length ≠ 2 (complete header → INVALID even without body).
    parse_ack_fail([0xb0, 0x00], honkmqtt::INVALID);
    parse_ack_fail([0xb0, 0x03], honkmqtt::INVALID);
    parse_ack_fail([0xb0, 0x01], honkmqtt::INVALID);

    // Zero Packet Identifier.
    parse_ack_fail([0xb0, 0x02, 0x00, 0x00], honkmqtt::INVALID);

    // Non-minimal Remaining Length.
    parse_ack_fail([0xb0, 0x82, 0x00, 0x00, 0x01], honkmqtt::INVALID);

    var out: u8[8] = [0; 8];
    encode_ack_fail(0, out, honkmqtt::INVALID);
    encode_ack_fail(65536, out, honkmqtt::INVALID);
    var tiny: u8[3] = [0; 3];
    encode_ack_fail(1, tiny, honkmqtt::NO_SPACE);
    encode_ack_fail(0, tiny, honkmqtt::INVALID);
}

fn unsubscribe_next_bounds() {
    let pkt: u8[7] = [0xa2, 0x05, 0x00, 0x01, 0x00, 0x01, 0x61];
    let st, used, _, lo, ll = honkmqtt::unsubscribe(pkt, 64);
    assert(st == honkmqtt::OK && used == 7);
    let end = lo + ll;

    let e1, _, _, _ = honkmqtt::unsubscribe_next(pkt, end, end);
    assert(e1 == honkmqtt::INVALID);
    let e2, _, _, _ = honkmqtt::unsubscribe_next(pkt, end + 1, end);
    assert(e2 == honkmqtt::INVALID);
    let e3, _, _, _ = honkmqtt::unsubscribe_next(pkt, -1, end);
    assert(e3 == honkmqtt::INVALID);
    let e4, _, _, _ = honkmqtt::unsubscribe_next(pkt, lo, pkt.len + 1);
    assert(e4 == honkmqtt::INVALID);
    // Truncated mid-entry: stop before filter data completes.
    let e5, _, _, _ = honkmqtt::unsubscribe_next(pkt, lo, lo + 2);
    assert(e5 == honkmqtt::INVALID);
    // Length past iterator end.
    let e6, _, _, _ = honkmqtt::unsubscribe_next(pkt, lo, lo + 1);
    assert(e6 == honkmqtt::INVALID);
}

fn boundary_filter() {
    // 65535-byte filter accept.
    var filt: u8[65535] = ['a'; 65535];
    var list: u8[65537] = [0; 65537];
    list[0] = 0xff;
    list[1] = 0xff;
    for i in filt.len { list[2 + i] = filt[i]; }
    var out: u8[65550] = [0; 65550];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_unsubscribe(1, list[0..2 + 65535], out);
    assert(es == honkmqtt::OK);
    // Remaining Length = 2 + 65537 = 65539 → literal fixed header A2 83 80 04.
    assert(out[0] == 0xa2 && out[1] == 0x83 && out[2] == 0x80 && out[3] == 0x04);
    let st, used, id, lo, ll = honkmqtt::unsubscribe(out[0..en], 70000);
    assert(st == honkmqtt::OK && used == en && id == 1 && ll == 2 + 65535);
    let ns, next, fo, fl = honkmqtt::unsubscribe_next(out, lo, lo + ll);
    assert(ns == honkmqtt::OK && fl == 65535 && next == lo + ll);
    assert(out[fo] == 'a' && out[fo + 65534] == 'a');

    // Two-byte length 0xFFFF with only partial data → missing-data INVALID.
    encode_unsub_fail(1, [0xff, 0xff, 0x61, 0x62], out[0..8], honkmqtt::INVALID);
    // Nominal short entry with trailing junk after a complete filter.
    encode_unsub_fail(1, [0x00, 0x01, 0x61, 0xff], out[0..8], honkmqtt::INVALID);
}

fn adjacent() {
    var buf: u8[32] = [0; 32];
    fill(buf, 0xee);
    let list: u8[3] = [0x00, 0x01, 0x61];
    let es, en = honkmqtt::encode_unsubscribe(1, list, buf);
    assert(es == honkmqtt::OK && en == 7);
    let as_, an = honkmqtt::encode_unsuback(1, buf[en..en + 8]);
    assert(as_ == honkmqtt::OK && an == 4);
    let ss, su, _, _, _ = honkmqtt::unsubscribe(buf[0..en + an], 64);
    assert(ss == honkmqtt::OK && su == en);
    let ks, ku, kid = honkmqtt::unsuback(buf[en..en + an]);
    assert(ks == honkmqtt::OK && ku == an && kid == 1);
    for i in en + an..buf.len { assert(buf[i] == 0xee); }
}

fn main() {
    literal_unsubscribe();
    literal_unsuback();
    truncations();
    malformed_unsubscribe();
    malformed_unsuback();
    unsubscribe_next_bounds();
    boundary_filter();
    adjacent();
    print("UNSUBSCRIBE/UNSUBACK tests passed");
}
