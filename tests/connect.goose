// Independent MQTT 3.1.1 CONNECT wire vectors (OASIS §§1.5.3, 2.2, 3.1).
// Expected bytes are asserted before round trips.
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

fn parse_ok(
    expect:     const u8[:],
    flags:      i64,
    keep_alive: i64,
    cid:        const u8[:],
    wt:         const u8[:],
    wm:         const u8[:],
    user:       const u8[:],
    pass:       const u8[:],
    has_will:   bool,
    has_user:   bool,
    has_pass:   bool,
) {
    let st, used, f, ka, co, cl, wto, wtl, wmo, wml, uo, ul, po, pl =
        honkmqtt::connect(expect, 65535);
    assert(st == honkmqtt::OK && used == expect.len);
    assert(f == flags && ka == keep_alive);
    assert(cl == cid.len);
    for i in cid.len { assert(expect[co + i] == cid[i]); }
    if has_will {
        assert((f & 4) != 0);
        assert(wtl == wt.len && wml == wm.len);
        for i in wt.len { assert(expect[wto + i] == wt[i]); }
        for i in wm.len { assert(expect[wmo + i] == wm[i]); }
    } else {
        assert((f & 4) == 0 && wto == 0 && wtl == 0 && wmo == 0 && wml == 0);
    }
    if has_user {
        assert((f & 128) != 0);
        assert(ul == user.len);
        for i in user.len { assert(expect[uo + i] == user[i]); }
    } else {
        assert((f & 128) == 0 && uo == 0 && ul == 0);
    }
    if has_pass {
        assert((f & 64) != 0);
        assert(pl == pass.len);
        for i in pass.len { assert(expect[po + i] == pass[i]); }
    } else {
        assert((f & 64) == 0 && po == 0 && pl == 0);
    }

    var with_trail: u8[64] = [0; 64];
    assert(expect.len + 1 <= with_trail.len);
    for i in expect.len { with_trail[i] = expect[i]; }
    with_trail[expect.len] = 0xc0;
    let st2, used2, f2, ka2, _, _, _, _, _, _, _, _, _, _ =
        honkmqtt::connect(with_trail[0..expect.len + 1], 65535);
    assert(st2 == honkmqtt::OK && used2 == expect.len && f2 == flags && ka2 == keep_alive);
}

fn parse_fail(input: const u8[:], max_body: i64, expected: i64) {
    let st, used, f, ka, co, cl, wto, wtl, wmo, wml, uo, ul, po, pl =
        honkmqtt::connect(input, max_body);
    assert(st == expected && used == 0);
    assert(f == 0 && ka == 0 && co == 0 && cl == 0);
    assert(wto == 0 && wtl == 0 && wmo == 0 && wml == 0);
    assert(uo == 0 && ul == 0 && po == 0 && pl == 0);
}

fn encode_ok(
    clean:        bool,
    keep_alive:   i64,
    client_id:    const u8[:],
    will:         bool,
    will_qos:     i64,
    will_retain:  bool,
    will_topic:   const u8[:],
    will_message: const u8[:],
    user:         bool,
    username:     const u8[:],
    pass:         bool,
    password:     const u8[:],
    expect:       const u8[:],
) {
    var out: u8[128] = [0; 128];
    fill(out, 0xa5);
    let st, n = honkmqtt::encode_connect(
        clean, keep_alive, client_id,
        will, will_qos, will_retain, will_topic, will_message,
        user, username, pass, password, out);
    assert(st == honkmqtt::OK && n == expect.len);
    eq_bytes(out, expect);
    for i in expect.len..out.len { assert(out[i] == 0xa5); }
}

fn vector_ok(
    clean:        bool,
    keep_alive:   i64,
    client_id:    const u8[:],
    will:         bool,
    will_qos:     i64,
    will_retain:  bool,
    will_topic:   const u8[:],
    will_message: const u8[:],
    user:         bool,
    username:     const u8[:],
    pass:         bool,
    password:     const u8[:],
    expect:       const u8[:],
) {
    var flags = 0;
    if clean { flags += 2; }
    if will {
        flags += 4;
        flags += will_qos * 8;
        if will_retain { flags += 32; }
    }
    if pass { flags += 64; }
    if user { flags += 128; }
    parse_ok(expect, flags, keep_alive, client_id, will_topic, will_message, username, password, will, user, pass);
    encode_ok(clean, keep_alive, client_id, will, will_qos, will_retain, will_topic, will_message, user, username, pass, password, expect);
}

fn encode_fail(
    clean:        bool,
    keep_alive:   i64,
    client_id:    const u8[:],
    will:         bool,
    will_qos:     i64,
    will_retain:  bool,
    will_topic:   const u8[:],
    will_message: const u8[:],
    user:         bool,
    username:     const u8[:],
    pass:         bool,
    password:     const u8[:],
    out:          u8[:],
    expected:     i64,
) {
    fill(out, 0x5a);
    let st, n = honkmqtt::encode_connect(
        clean, keep_alive, client_id,
        will, will_qos, will_retain, will_topic, will_message,
        user, username, pass, password, out);
    assert(st == expected && n == 0);
    unchanged(out, 0x5a);
}

fn literal_vectors() {
    // Clean Session, Client ID "a", Keep Alive 0.
    let v1: u8[15] = [
        0x10, 0x0d,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x02, 0x00, 0x00,
        0x00, 0x01, 0x61,
    ];
    vector_ok(true, 0, "a", false, 0, false, "", "", false, "", false, "", v1);

    // Empty Client ID with Clean Session (structurally legal; broker assigns id).
    let v2: u8[14] = [
        0x10, 0x0c,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x02, 0x00, 0x00,
        0x00, 0x00,
    ];
    vector_ok(true, 0, "", false, 0, false, "", "", false, "", false, "", v2);

    // Clean Session clear, Client ID "ab", Keep Alive 10.
    let v3: u8[16] = [
        0x10, 0x0e,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x00, 0x00, 0x0a,
        0x00, 0x02, 0x61, 0x62,
    ];
    vector_ok(false, 10, "ab", false, 0, false, "", "", false, "", false, "", v3);

    // Will QoS 1 + Retain, User Name + Password (all nonempty).
    // Flags: user|pass|retain|qos1|will|clean = 0b11101110 = 0xEE
    // Remaining Length = 10 + 3+3+3+3+3 = 25.
    let v4: u8[27] = [
        0x10, 0x19,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0xee, 0x00, 0x3c,
        0x00, 0x01, 0x63,
        0x00, 0x01, 0x74,
        0x00, 0x01, 0x6d,
        0x00, 0x01, 0x75,
        0x00, 0x01, 0x70,
    ];
    vector_ok(true, 60, "c", true, 1, true, "t", "m", true, "u", true, "p", v4);

    // Present-empty User Name and Password; empty Will Message; Will QoS 0.
    // Flags: user|pass|will|clean = 0b11000110 = 0xC6
    // Remaining Length = 10 + 3+3+2+2+2 = 22.
    let v5: u8[24] = [
        0x10, 0x16,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0xc6, 0x00, 0x01,
        0x00, 0x01, 0x78,
        0x00, 0x01, 0x77,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ];
    vector_ok(true, 1, "x", true, 0, false, "w", "", true, "", true, "", v5);

    // User Name without Password; Will QoS 2 no retain; binary Will Message.
    // Flags: user|qos2|will = 0b10010100 = 0x94
    // Remaining Length = 10 + 4+5+4+3 = 26.
    let will_bin: u8[2] = [0x00, 0xff];
    let v6: u8[28] = [
        0x10, 0x1a,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x94, 0xff, 0xff,
        0x00, 0x02, 0x69, 0x64,
        0x00, 0x03, 0x61, 0x2f, 0x62,
        0x00, 0x02, 0x00, 0xff,
        0x00, 0x01, 0x6e,
    ];
    vector_ok(false, 65535, "id", true, 2, false, "a/b", will_bin, true, "n", false, "", v6);

    // Long-ish UTF-8 Client ID (>23) accepted structurally (server policy out of scope).
    let long_id = "abcdefghijklmnopqrstuvwx";
    assert(long_id.len == 24);
    var v7: u8[48] = [0; 48];
    v7[0] = 0x10;
    v7[1] = 10 + 2 + 24;
    v7[2] = 0; v7[3] = 4;
    v7[4] = 0x4d; v7[5] = 0x51; v7[6] = 0x54; v7[7] = 0x54;
    v7[8] = 4; v7[9] = 2; v7[10] = 0; v7[11] = 0;
    v7[12] = 0; v7[13] = 24;
    for i in long_id.len { v7[14 + i] = long_id[i]; }
    let v7_pkt = v7[0..14 + 24];
    vector_ok(true, 0, long_id, false, 0, false, "", "", false, "", false, "", v7_pkt);
}

fn truncations() {
    let pkt: u8[15] = [
        0x10, 0x0d,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x02, 0x00, 0x00,
        0x00, 0x01, 0x61,
    ];
    parse_fail("", 65535, honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..1], 65535, honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..2], 65535, honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..10], 65535, honkmqtt::INCOMPLETE);
    parse_fail(pkt[0..14], 65535, honkmqtt::INCOMPLETE);
    let st, used, _, _, _, _, _, _, _, _, _, _, _, _ = honkmqtt::connect(pkt, 65535);
    assert(st == honkmqtt::OK && used == 15);
}

fn remaining_bounds() {
    assert(honkmqtt::CONNECT_MIN_REMAINING == 12);
    assert(honkmqtt::CONNECT_MAX_REMAINING == 327695);

    // Header-only: RL below structural minimum → INVALID (not INCOMPLETE).
    parse_fail([0x10, 0x0b], 65535, honkmqtt::INVALID);
    parse_fail([0x10, 0x00], 65535, honkmqtt::INVALID);

    // Header-only: RL at structural maximum 327695 = VLQ 8F 80 14 → INCOMPLETE.
    parse_fail([0x10, 0x8f, 0x80, 0x14], honkmqtt::CONNECT_MAX_REMAINING, honkmqtt::INCOMPLETE);

    // Header-only: RL above structural maximum 327696 = VLQ 90 80 14 → INVALID.
    parse_fail([0x10, 0x90, 0x80, 0x14], honkmqtt::MAX_REMAINING, honkmqtt::INVALID);

    // Full at-limit packet: VH(10) + five 2+65535 fields = 327695.
    var cid:  u8[65535]  = ['a'; 65535];
    var wt:   u8[65535]  = ['b'; 65535];
    var wm:   u8[65535]  = [0x5a; 65535];
    var user: u8[65535]  = ['u'; 65535];
    var pass: u8[65535]  = [0x00; 65535];
    var out:  u8[327700] = [0; 327700];
    fill(out, 0xa5);
    let es, en = honkmqtt::encode_connect(
        true, 0, cid,
        true, 0, false, wt, wm,
        true, user, true, pass, out);
    assert(es == honkmqtt::OK);
    assert(en == 4 + honkmqtt::CONNECT_MAX_REMAINING);
    assert(out[0] == 0x10);
    assert(out[1] == 0x8f && out[2] == 0x80 && out[3] == 0x14);
    let st, used, flags, _, co, cl, wto, wtl, wmo, wml, uo, ul, po, pl =
        honkmqtt::connect(out[0..en], honkmqtt::CONNECT_MAX_REMAINING);
    assert(st == honkmqtt::OK && used == en);
    assert((flags & 0xc6) == 0xc6);
    assert(cl == 65535 && wtl == 65535 && wml == 65535 && ul == 65535 && pl == 65535);
    assert(out[co] == 'a' && out[wto] == 'b' && out[wmo] == 0x5a);
    assert(out[uo] == 'u' && out[po] == 0x00);
}

fn malformed() {
    // Wrong fixed-header flags.
    parse_fail([0x11, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);
    // Wrong type with otherwise valid CONNECT Remaining Length/body (isolates type).
    parse_fail([0x30, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Wrong protocol name / level.
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x74, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);
    parse_fail([0x10, 0x0c, 0x00, 0x03, 0x4d, 0x51, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x03, 0x02, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Reserved Connect Flag bit 0 set.
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x03, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Will Flag clear but Will QoS / Retain set; Clean Session set with empty
    // Client ID so removing the dependent-flag check alone would accept these.
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x0a, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x22, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Will Flag set, Will QoS 3; RL 18 matches Client ID + Will Topic/Message.
    parse_fail([0x10, 0x12, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x1c, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00, 0x01, 0x74, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Password without User Name.
    parse_fail([0x10, 0x0e, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Empty Client ID without Clean Session.
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Will Topic with wildcard / empty (not a valid topic name); RL matches body.
    parse_fail([0x10, 0x12, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x06, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00, 0x01, 0x2b, 0x00, 0x00], 65535, honkmqtt::INVALID);
    parse_fail([0x10, 0x11, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x06, 0x00, 0x00, 0x00, 0x01, 0x61, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    // Client ID with U+0000.
    parse_fail([0x10, 0x0d, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00], 65535, honkmqtt::INVALID);

    // Length prefix past Remaining Length (complete frame → INVALID, not INCOMPLETE).
    parse_fail([0x10, 0x0c, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x05], 65535, honkmqtt::INVALID);

    // Trailing junk inside Remaining Length after Client ID.
    parse_fail([0x10, 0x0d, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0xff], 65535, honkmqtt::INVALID);

    // Will Flag set but Will fields missing (RL ends after Client ID).
    parse_fail([0x10, 0x0d, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x06, 0x00, 0x00, 0x00, 0x01, 0x61], 65535, honkmqtt::INVALID);

    // max_body too small / negative.
    let good: u8[15] = [
        0x10, 0x0d,
        0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
        0x04, 0x02, 0x00, 0x00,
        0x00, 0x01, 0x61,
    ];
    parse_fail(good, 12, honkmqtt::INVALID);
    parse_fail(good, -1, honkmqtt::INVALID);

    // Non-minimal Remaining Length.
    parse_fail([0x10, 0x8c, 0x00, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00], 65535, honkmqtt::INVALID);

    var out: u8[64] = [0; 64];
    encode_fail(true, -1, "a", false, 0, false, "", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(true, 65536, "a", false, 0, false, "", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(false, 0, "", false, 0, false, "", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(true, 0, "a", false, 1, false, "", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(true, 0, "a", true, 3, false, "t", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(true, 0, "a", true, 0, false, "+", "", false, "", false, "", out, honkmqtt::INVALID);
    encode_fail(true, 0, "a", false, 0, false, "", "", false, "", true, "p", out, honkmqtt::INVALID);
    encode_fail(true, 0, "\x00", false, 0, false, "", "", false, "", false, "", out, honkmqtt::INVALID);
    var tiny: u8[4] = [0; 4];
    encode_fail(true, 0, "a", false, 0, false, "", "", false, "", false, "", tiny, honkmqtt::NO_SPACE);
    // INVALID before NO_SPACE.
    encode_fail(false, 0, "", false, 0, false, "", "", false, "", false, "", tiny, honkmqtt::INVALID);
    encode_fail(true, 0, "a", false, 0, false, "", "", false, "", true, "p", tiny, honkmqtt::INVALID);
}

fn boundaries_and_adjacent() {
    // Binary Will Message / Password with embedded 0x00.
    let bin: u8[2] = [0x00, 0xff];
    var out: u8[64] = [0; 64];
    fill(out, 0xee);
    let es, en = honkmqtt::encode_connect(
        true, 0, "c",
        true, 0, false, "t", bin,
        true, "u", true, bin, out);
    assert(es == honkmqtt::OK && en > 0);
    let ps, used, f, _, _, _, _, _, wmo, wml, _, _, po, pl =
        honkmqtt::connect(out[0..en], 65535);
    assert(ps == honkmqtt::OK && used == en);
    assert((f & 4) != 0 && (f & 64) != 0 && (f & 128) != 0);
    assert(wml == 2 && pl == 2);
    assert(out[wmo] == 0x00 && out[wmo + 1] == 0xff);
    assert(out[po] == 0x00 && out[po + 1] == 0xff);

    // Adjacent PINGREQ after CONNECT left unconsumed.
    assert(en + 2 <= out.len);
    let ps2, pn = honkmqtt::encode(0xc0, "", out[en..en + 2]);
    assert(ps2 == honkmqtt::OK && pn == 2);
    let ok, used2, _, _, _, _, _, _, _, _, _, _, _, _ =
        honkmqtt::connect(out[0..en + 2], 65535);
    assert(ok == honkmqtt::OK && used2 == en);
    let fs, fu = honkmqtt::frame(out[en..en + 2], 0);
    assert(fs == honkmqtt::OK && fu == 2);
    for i in en + 2..out.len { assert(out[i] == 0xee); }
}

fn main() {
    literal_vectors();
    truncations();
    remaining_bounds();
    malformed();
    boundaries_and_adjacent();
    print("CONNECT tests passed");
}
