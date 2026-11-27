// Independent bounded transport-adapter vectors for M3 (example helper).
// Exact wire bytes and ordering are asserted; short I/O is deterministic.
import honkmqtt from "..";
import stream from "../examples/stream";
import std;

const RX_CAP = 64;
const TX_CAP = 32;
const MAX_BODY = RX_CAP - stream::HEADER_MAX; // 59

fn eq_prefix(got: const u8[:], expect: const u8[:]) {
    assert(got.len >= expect.len);
    for i in expect.len { assert(got[i] == expect[i]); }
}

fn try_frame(rx: const u8[:], start: i64, end: i64) -> i64, i64 {
    return honkmqtt::frame(rx[start..end], MAX_BODY);
}

fn capacity_contract() {
    assert(stream::HEADER_MAX == 5);
    assert(stream::rx_capacity_for(MAX_BODY) == RX_CAP);
    assert(stream::rx_capacity_for(-1) == -1);
    assert(stream::rx_capacity_for(stream::MAX_BODY - stream::HEADER_MAX) == stream::MAX_BODY);
    assert(stream::rx_capacity_for(stream::MAX_BODY - stream::HEADER_MAX + 1) == -1);
}

fn feed_short_and_wait() {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    fill(rx, 0xa5);
    var s = 0;
    var e = 0;

    let w, ws, we, t = stream::feed(rx, s, e, [0xc0, 0x00], 0);
    assert(w == stream::WAIT && ws == 0 && we == 0 && t == 0);
    assert(rx[0] == 0xa5);

    let s1, ns1, ne1, t1 = stream::feed(rx, s, e, [0xc0, 0x00], 1);
    assert(s1 == stream::OK && ns1 == 0 && ne1 == 1 && t1 == 1 && rx[0] == 0xc0);
    s = ns1;
    e = ne1;
    let f1, u1 = try_frame(rx, s, e);
    assert(f1 == honkmqtt::INCOMPLETE && u1 == 0);

    let s2, ns2, ne2, t2 = stream::feed(rx, s, e, [0x00], 1);
    assert(s2 == stream::OK && ne2 == 2 && t2 == 1 && rx[1] == 0x00);
    s = ns2;
    e = ne2;
    let f2, u2 = try_frame(rx, s, e);
    assert(f2 == honkmqtt::OK && u2 == 2);
    eq_prefix(rx[s..s + u2], [0xc0, 0x00]);

    let cs, ns3, ne3 = stream::commit_rx(s, e, u2);
    assert(cs == stream::OK && ns3 == 2 && ne3 == 2);
    assert(stream::pending(ns3, ne3) == 0);
}

fn fragmented_multibyte_header() {
    var body: u8[128] = [0x5a; 128];
    var pkt:  u8[140] = [0; 140];
    let es, en = honkmqtt::encode(0x30, body, pkt);
    assert(es == honkmqtt::OK && en == 1 + 2 + 128);
    assert(pkt[0] == 0x30 && pkt[1] == 0x80 && pkt[2] == 0x01);

    var big: u8[160] = [0; 160];
    var s = 0;
    var e = 0;
    let s0, ns0, ne0, t0 = stream::feed(big, s, e, pkt[0..1], 1);
    assert(s0 == stream::OK && t0 == 1);
    s = ns0;
    e = ne0;
    let h0, hp0, hb0 = honkmqtt::header(big[s..e]);
    assert(h0 == honkmqtt::INCOMPLETE && hp0 == 0 && hb0 == 0);

    let s1, ns1, ne1, t1 = stream::feed(big, s, e, pkt[1..2], 1);
    assert(s1 == stream::OK && t1 == 1);
    s = ns1;
    e = ne1;
    let h1, hp1, hb1 = honkmqtt::header(big[s..e]);
    assert(h1 == honkmqtt::INCOMPLETE && hp1 == 0 && hb1 == 0);

    let s2, ns2, ne2, t2 = stream::feed(big, s, e, pkt[2..3], 1);
    assert(s2 == stream::OK && t2 == 1);
    s = ns2;
    e = ne2;
    let h2, hp, hb = honkmqtt::header(big[s..e]);
    assert(h2 == honkmqtt::OK && hp == 3 && hb == 128);
    let f2, u2 = honkmqtt::frame(big[s..e], 128);
    assert(f2 == honkmqtt::INCOMPLETE && u2 == 0);

    var off = 3;
    while off < en {
        var chunk = 32;
        if chunk > en - off { chunk = en - off; }
        let fs, ns, ne, ft = stream::feed(big, s, e, pkt[off..off + chunk], chunk);
        assert(fs == stream::OK && ft == chunk);
        s = ns;
        e = ne;
        off += chunk;
    }
    assert(stream::pending(s, e) == en);
    let f3, u3 = honkmqtt::frame(big[s..e], 128);
    assert(f3 == honkmqtt::OK && u3 == en);
    eq_prefix(big[s..s + 3], [0x30, 0x80, 0x01]);
}

fn adjacent_packets() {
    let wire: u8[6] = [0xc0, 0x00, 0xd0, 0x00, 0xe0, 0x00];
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var s = 0;
    var e = 0;

    for i in wire.len {
        let st, ns, ne, t = stream::feed(rx, s, e, wire[i..i + 1], 1);
        assert(st == stream::OK && t == 1);
        s = ns;
        e = ne;
    }
    assert(stream::pending(s, e) == 6);

    let a, ua = try_frame(rx, s, e);
    assert(a == honkmqtt::OK && ua == 2);
    eq_prefix(rx[s..s + 2], [0xc0, 0x00]);
    let _, s1, e1 = stream::commit_rx(s, e, ua);
    s = s1;
    e = e1;

    let b, ub = try_frame(rx, s, e);
    assert(b == honkmqtt::OK && ub == 2);
    eq_prefix(rx[s..s + 2], [0xd0, 0x00]);
    let _, s2, e2 = stream::commit_rx(s, e, ub);
    s = s2;
    e = e2;

    let c, uc = try_frame(rx, s, e);
    assert(c == honkmqtt::OK && uc == 2);
    eq_prefix(rx[s..s + 2], [0xe0, 0x00]);
    let _, s3, e3 = stream::commit_rx(s, e, uc);
    assert(stream::pending(s3, e3) == 0);
}

fn eof_incomplete_vs_complete() {
    // Incomplete prefix at EOF → TRUNCATED (after no complete frame remains).
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var s = 0;
    var e = 0;
    let st, ns, ne, _ = stream::feed(rx, s, e, [0xc0], 1);
    assert(st == stream::OK);
    s = ns;
    e = ne;
    let f, u = try_frame(rx, s, e);
    assert(f == honkmqtt::INCOMPLETE && u == 0);
    assert(stream::on_eof(stream::pending(s, e)) == stream::TRUNCATED);

    // Complete frame still buffered: drain it before EOF classification.
    var rx2: u8[RX_CAP] = [0; RX_CAP];
    var s2 = 0;
    var e2 = 0;
    let st2, ns2, ne2, _ = stream::feed(rx2, s2, e2, [0xc0, 0x00], 2);
    assert(st2 == stream::OK);
    s2 = ns2;
    e2 = ne2;
    let f2, u2 = try_frame(rx2, s2, e2);
    assert(f2 == honkmqtt::OK && u2 == 2);
    let _, s3, e3 = stream::commit_rx(s2, e2, u2);
    assert(stream::on_eof(stream::pending(s3, e3)) == stream::CLOSED);
}

fn fatal_framing_stops() {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var s = 0;
    var e = 0;
    let st, ns, ne, _ = stream::feed(rx, s, e, [0x00, 0x00], 2);
    assert(st == stream::OK);
    s = ns;
    e = ne;
    let f, u = try_frame(rx, s, e);
    assert(f == honkmqtt::INVALID && u == 0);
    // Fatal: do not commit; window retained for diagnostics.
    assert(stream::pending(s, e) == 2 && rx[s] == 0x00 && rx[s + 1] == 0x00);
}

fn rx_backpressure_and_compact() {
    var rx: u8[4] = [0; 4];
    var s = 0;
    var e = 0;
    let s1, ns1, ne1, t1 = stream::feed(rx, s, e, [1, 2, 3, 4, 5], 8);
    assert(s1 == stream::OK && ne1 == 4 && t1 == 4);
    s = ns1;
    e = ne1;
    let s2, ns2, ne2, t2 = stream::feed(rx, s, e, [9], 1);
    assert(s2 == stream::NO_SPACE && t2 == 0 && ns2 == s && ne2 == e);
    assert(rx[0] == 1 && rx[3] == 4);

    // Commit two bytes, then feed must compact before appending.
    let _, s3, e3 = stream::commit_rx(s, e, 2);
    s = s3;
    e = e3;
    assert(s == 2 && e == 4);
    let s4, ns4, ne4, t4 = stream::feed(rx, s, e, [9, 8], 2);
    assert(s4 == stream::OK && t4 == 2 && ns4 == 0 && ne4 == 4);
    assert(rx[0] == 3 && rx[1] == 4 && rx[2] == 9 && rx[3] == 8);
}

// After consuming a full buffer, start==end==len; compact/reset reclaim so a
// later RECV can land a complete MQTT frame (PINGREQ).
fn feed_after_empty_window_at_capacity() {
    var rx: u8[4] = [0; 4];
    var s = 0;
    var e = 0;
    let f0, ns0, ne0, t0 = stream::feed(rx, s, e, [0xc0, 0x00, 0xd0, 0x00], 4);
    assert(f0 == stream::OK && t0 == 4 && ne0 == 4);
    s = ns0;
    e = ne0;
    let fs0, used0 = try_frame(rx, s, e);
    assert(fs0 == honkmqtt::OK && used0 == 2);
    let _, s1, e1 = stream::commit_rx(s, e, used0);
    s = s1;
    e = e1;
    let fs1, used1 = try_frame(rx, s, e);
    assert(fs1 == honkmqtt::OK && used1 == 2);
    let _, s2, e2 = stream::commit_rx(s, e, used1);
    s = s2;
    e = e2;
    assert(s == 4 && e == 4);
    // Explicit compact/reset of empty window at capacity (TCP session policy).
    let cs, ns, ne = stream::compact(rx, s, e);
    assert(cs == stream::OK && ns == 0 && ne == 0);
    let f3, ns3, ne3, t3 = stream::feed(rx, ns, ne, [0xc0, 0x00], 2);
    assert(f3 == stream::OK && t3 == 2 && ns3 == 0 && ne3 == 2);
    let fs3, used3 = try_frame(rx, ns3, ne3);
    assert(fs3 == honkmqtt::OK && used3 == 2);
    let pr, _ = honkmqtt::pingreq(rx[ns3..ns3 + used3]);
    assert(pr == honkmqtt::OK);
}

// Fragmented valid PINGREQ near a 1-byte free tail: type byte lands without
// compact; Remaining Length needs compact then completes the frame.
fn feed_free_tail_before_compact() {
    var rx: u8[7] = [0; 7];
    var s = 0;
    var e = 0;
    // Three complete PINGREQ frames (6 bytes); free tail = 1.
    let f0, ns0, ne0, t0 = stream::feed(rx, s, e, [0xc0, 0x00, 0xc0, 0x00, 0xc0, 0x00], 6);
    assert(f0 == stream::OK && t0 == 6 && ns0 == 0 && ne0 == 6);
    s = ns0;
    e = ne0;
    assert(rx.len - e == 1);
    // First fragment: only the type byte into the short tail.
    let f1, ns1, ne1, t1 = stream::feed(rx, s, e, [0xc0], 1);
    assert(f1 == stream::OK && t1 == 1 && ns1 == 0 && ne1 == 7);
    s = ns1;
    e = ne1;
    // Drain the three complete frames; trailing type byte stays INCOMPLETE.
    for i in 3 {
        let fs, used = try_frame(rx, s, e);
        assert(fs == honkmqtt::OK && used == 2);
        let _, ns, ne = stream::commit_rx(s, e, used);
        s = ns;
        e = ne;
        let _ = i;
    }
    let fs_inc, _ = try_frame(rx, s, e);
    assert(fs_inc == honkmqtt::INCOMPLETE && e - s == 1 && rx[s] == 0xc0);
    // Tail full with pending prefix — compact then feed Remaining Length.
    assert(rx.len - e == 0);
    let cs, ns2, ne2 = stream::compact(rx, s, e);
    assert(cs == stream::OK && ns2 == 0 && ne2 == 1);
    let f2, ns3, ne3, t2 = stream::feed(rx, ns2, ne2, [0x00], 1);
    assert(f2 == stream::OK && t2 == 1 && ns3 == 0 && ne3 == 2);
    let fs_ok, used = try_frame(rx, ns3, ne3);
    assert(fs_ok == honkmqtt::OK && used == 2);
    let pr, _ = honkmqtt::pingreq(rx[ns3..ns3 + used]);
    assert(pr == honkmqtt::OK);
}

// Coalesced first frame + forbidden PINGRESP must both be visible when draining
// before peer-close (session wait_peer_close policy).
fn coalesced_frames_before_eof() {
    var rx: u8[8] = [0; 8];
    var s = 0;
    var e = 0;
    // CONNACK (4) + PINGRESP (2) delivered in one feed (coalesced TCP read).
    let blob: u8[6] = [0x20, 0x02, 0x00, 0x00, 0xd0, 0x00];
    let f0, ns0, ne0, t0 = stream::feed(rx, s, e, blob, 6);
    assert(f0 == stream::OK && t0 == 6 && ne0 == 6);
    s = ns0;
    e = ne0;
    let fs0, used0 = try_frame(rx, s, e);
    assert(fs0 == honkmqtt::OK && used0 == 4);
    let ca, _, session, code = honkmqtt::connack(rx[s..s + used0]);
    assert(ca == honkmqtt::OK && !session && code == 0);
    let _, s1, e1 = stream::commit_rx(s, e, used0);
    s = s1;
    e = e1;
    // Second complete frame still buffered — must be inspected before EOF.
    let fs1, used1 = try_frame(rx, s, e);
    assert(fs1 == honkmqtt::OK && used1 == 2);
    let pr, _ = honkmqtt::pingresp(rx[s..s + used1]);
    assert(pr == honkmqtt::OK);
}

fn short_writes_commit_only() {
    var tx: u8[TX_CAP] = [0; TX_CAP];
    fill(tx, 0xee);
    var s = 0;
    var e = 0;

    let ping: u8[2] = [0xc0, 0x00];
    let resp: u8[2] = [0xd0, 0x00];
    let e1, s1, e1e = stream::enqueue(tx, s, e, ping);
    assert(e1 == stream::OK && s1 == 0 && e1e == 2);
    s = s1;
    e = e1e;
    let e2, s2, e2e = stream::enqueue(tx, s, e, resp);
    assert(e2 == stream::OK && e2e == 4);
    s = s2;
    e = e2e;
    eq_prefix(tx[0..4], [0xc0, 0x00, 0xd0, 0x00]);

    var big: u8[TX_CAP] = [0x11; TX_CAP];
    let e3, s3, e3e = stream::enqueue(tx, s, e, big);
    assert(e3 == stream::NO_SPACE && s3 == s && e3e == e);
    eq_prefix(tx[0..4], [0xc0, 0x00, 0xd0, 0x00]);

    let w, wn = stream::drain(s, e, 0);
    assert(w == stream::WAIT && wn == 0);

    // Short write: commit advances start; remaining bytes stay put (no shift).
    let d1, dn1 = stream::drain(s, e, 1);
    assert(d1 == stream::OK && dn1 == 1 && tx[s] == 0xc0);
    let before1 = tx[1];
    let before2 = tx[2];
    let before3 = tx[3];
    let _, ns, ne = stream::commit_tx(s, e, dn1);
    s = ns;
    e = ne;
    assert(s == 1 && e == 4);
    assert(tx[1] == before1 && tx[2] == before2 && tx[3] == before3);
    eq_prefix(tx[s..e], [0x00, 0xd0, 0x00]);

    let d2, dn2 = stream::drain(s, e, 2);
    assert(d2 == stream::OK && dn2 == 2);
    eq_prefix(tx[s..s + 2], [0x00, 0xd0]);
    let _, s4, e4 = stream::commit_tx(s, e, dn2);
    s = s4;
    e = e4;
    let d3, dn3 = stream::drain(s, e, 8);
    assert(d3 == stream::OK && dn3 == 1 && tx[s] == 0x00);
    let _, s5, e5 = stream::commit_tx(s, e, dn3);
    assert(stream::pending(s5, e5) == 0);
    let d4, dn4 = stream::drain(s5, e5, 1);
    assert(d4 == stream::WAIT && dn4 == 0);
}

// Enqueue must compact when the packet does not fit the remaining tail even
// though unused tail bytes remain (start > 0, end < capacity). Packet storage
// is a separate buffer (full-TX disjointness).
fn enqueue_compact_with_partly_free_tail() {
    var tx: u8[TX_CAP] = [0; TX_CAP];
    fill(tx, 0xee);
    var s = 0;
    var e = 0;

    var prefix: u8[20] = [0; 20];
    for i in prefix.len { prefix[i] = (i + 1) as u8; }
    let e0, s0, e0e = stream::enqueue(tx, s, e, prefix);
    assert(e0 == stream::OK && s0 == 0 && e0e == 20);
    s = s0;
    e = e0e;

    let _, ns, ne = stream::commit_tx(s, e, 10);
    s = ns;
    e = ne;
    assert(s == 10 && e == 20);
    // Tail free = 12, total free = 22; packet len 15 needs compact.
    assert(TX_CAP - e == 12);
    assert(TX_CAP - (e - s) == 22);

    // Mark consumed head so a successful compact must overwrite it.
    for i in s { tx[i] = 0xaa; }

    var pkt: u8[15] = [0; 15];
    for i in pkt.len { pkt[i] = (0x40 + i) as u8; }
    let e1, s1, e1e = stream::enqueue(tx, s, e, pkt);
    assert(e1 == stream::OK && s1 == 0 && e1e == 25);
    eq_prefix(tx[0..10], [11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
    eq_prefix(tx[10..25], pkt);
}

fn body_limit_in_rx_window(prefix: const u8[:]) {
    var rx: u8[133] = [0xa5; 133];
    let fed, start, end, taken = stream::feed(rx, 0, 0, prefix, prefix.len);
    assert(fed == stream::OK && start == 0 && end == 5 && taken == 5);
    let committed, s, e = stream::commit_rx(start, end, 2);
    assert(committed == stream::OK && s == 2 && e == 5);
    // The complete header declares 128 bytes; the body has not arrived.
    let at_limit, used_at = honkmqtt::frame(rx[s..e], 128);
    assert(at_limit == honkmqtt::INCOMPLETE && used_at == 0);
    let over_limit, used_over = honkmqtt::frame(rx[s..e], 127);
    assert(over_limit == honkmqtt::INVALID && used_over == 0);
    eq_prefix(rx[0..e], prefix);
    for i in rx.len - e { assert(rx[e + i] == 0xa5); }
}

// Independent MQTT 3.1.1 §2.2 vectors, assembled into bounded varied frame
// sequences. The seeded choices vary frame order, count, and short-read size;
// expected wire bytes come from this table, not from an encoder/parser pair.
fn copy_vector(id: i64, out: u8[:], at: i64) -> i64 {
    if id == 0 { out[at] = 0xc0; out[at + 1] = 0x00; return 2; }
    if id == 1 { out[at] = 0xd0; out[at + 1] = 0x00; return 2; }
    if id == 2 { out[at] = 0xe0; out[at + 1] = 0x00; return 2; }
    if id == 3 { out[at] = 0x40; out[at + 1] = 0x02; out[at + 2] = 0x12; out[at + 3] = 0x34; return 4; }
    if id == 4 { out[at] = 0x40; out[at + 1] = 0x02; out[at + 2] = 0xab; out[at + 3] = 0xcd; return 4; }
    if id == 5 { out[at] = 0x20; out[at + 1] = 0x02; out[at + 2] = 0x00; out[at + 3] = 0x00; return 4; }
    if id == 6 { out[at] = 0x30; out[at + 1] = 0x04; out[at + 2] = 0x00; out[at + 3] = 0x01; out[at + 4] = 0x74; out[at + 5] = 0x7a; return 6; }
    assert(false);
    return 0;
}

fn seeded_varied_valid_sequences() {
    const CASES = 64;
    const MAX_FRAMES = 24;
    const MAX_WIRE = MAX_FRAMES * 6;
    const RX = 32;
    const seed: u64 = 20261128;
    var total_frames = 0;
    var total_bytes = 0;
    var peak_rx = 0;
    var incomplete = 0;
    for case in CASES {
        var schedule = rng { seed + case as u64 };
        let count = 1 + schedule.rand_int(MAX_FRAMES);
        var kinds:    i64[24] = [0; 24];
        var begins:   i64[25] = [0; 25];
        var expected: u8[144] = [0; 144];
        var wire_len = 0;
        for n in count {
            let kind = schedule.rand_int(7);
            kinds[n] = kind;
            begins[n + 1] = begins[n] + copy_vector(kind, expected, wire_len);
            wire_len = begins[n + 1];
        }

        var rx: u8[32] = [0xa5; 32];
        var rs = 0;
        var re = 0;
        var admitted = 0;
        var handled = 0;
        while handled < count {
            if admitted < wire_len {
                let cap = 1 + schedule.rand_int(11);
                let fs, ns, ne, n = stream::feed(rx, rs, re, expected[admitted..wire_len], cap);
                assert(fs == stream::OK && n > 0 && n <= cap);
                rs = ns;
                re = ne;
                admitted += n;
            }
            peak_rx = max(peak_rx, re - rs);
            let frame_status, consumed = honkmqtt::frame(rx[rs..re], 16);
            if admitted < begins[handled + 1] {
                assert(frame_status == honkmqtt::INCOMPLETE && consumed == 0);
                incomplete += 1;
            } else {
                assert(frame_status == honkmqtt::OK);
                assert(consumed == begins[handled + 1] - begins[handled]);
                eq_prefix(rx[rs..rs + consumed], expected[begins[handled]..begins[handled + 1]]);
                if kinds[handled] == 3 || kinds[handled] == 4 {
                    let ack, used, id = honkmqtt::pubresp(rx[rs..rs + consumed], honkmqtt::PUBACK);
                    assert(ack == honkmqtt::OK && used == consumed);
                    if kinds[handled] == 3 { assert(id == 0x1234); }
                    else { assert(id == 0xabcd); }
                }
                let cs, ns, ne = stream::commit_rx(rs, re, consumed);
                assert(cs == stream::OK);
                rs = ns;
                re = ne;
                handled += 1;
            }
            assert(re - rs <= 32 && admitted - begins[handled] == re - rs);
        }
        assert(admitted == wire_len && rs == re);
        total_frames += count;
        total_bytes += wire_len;
    }
    print("Varied transport seed=", seed, " cases=", CASES, " frames=", total_frames,
          " bytes=", total_bytes, " peak_rx=", peak_rx, " incomplete=", incomplete);
    assert(total_frames > 700 && total_bytes < 64 * 144 && peak_rx <= 32 && incomplete > 0);
}

fn malformed_length_window_contracts() {
    // Remaining Length continuation with no terminator yet is incomplete and
    // consumes zero. Four-byte maximum is rejected against the configured cap
    // before the declared body arrives; the input remains byte-for-byte intact.
    var rx: u8[8] = [0xa5; 8];
    let truncated: u8[3] = [0x30, 0x80, 0x80];
    let fs, s, e, n = stream::feed(rx, 0, 0, truncated, 3);
    assert(fs == stream::OK && s == 0 && e == 3 && n == 3);
    let incomplete, used = honkmqtt::frame(rx[0..3], 128);
    assert(incomplete == honkmqtt::INCOMPLETE && used == 0);
    assert(rx[0] == 0x30 && rx[1] == 0x80 && rx[2] == 0x80 && rx[3] == 0xa5);

    let too_large: u8[5] = [0x30, 0xff, 0xff, 0xff, 0x7f];
    let fs2, s2, e2, n2 = stream::feed(rx, 0, 0, too_large, 5);
    assert(fs2 == stream::OK && s2 == 0 && e2 == 5 && n2 == 5);
    let invalid, used2 = honkmqtt::frame(rx[0..5], 128);
    assert(invalid == honkmqtt::INVALID && used2 == 0);
    assert(rx[0] == 0x30 && rx[1] == 0xff && rx[2] == 0xff && rx[3] == 0xff && rx[4] == 0x7f);
    assert(rx[5] == 0xa5 && rx[6] == 0xa5 && rx[7] == 0xa5);
}

fn seeded_transport_replay() {
    // MQTT 3.1.1 §§2.2.2–2.2.3: PINGREQ, QoS 0 PUBLISH (RL=128,
    // topic "t", payload 0..124), PUBACK, PINGREQ, PUBACK, DISCONNECT.
    // The wire and frame offsets are independent of all codec outputs.
    let wire: u8[145] = [
        0xc0, 0x00, 0x30, 0x80, 0x01, 0x00, 0x01, 0x74,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
        80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
        96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109,
        110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124,
        0x40, 0x02, 0x12, 0x34, 0xc0, 0x00, 0x40, 0x02, 0x56, 0x78, 0xe0, 0x00,
    ];
    let offsets = [0, 2, 133, 137, 139, 143, 145];
    body_limit_in_rx_window(wire[0..5]);

    let seed: u64 = 20261127;
    let cases = 128;
    var incomplete = 0;
    var rx_wait = 0;
    var rx_compact = 0;
    var tx_blocked = 0;
    var tx_wait = 0;
    var tx_short = 0;
    var tx_compact = 0;
    var peak_rx = 0;
    var peak_tx = 0;
    var peak_turns = 0;
    var peak_idle = 0;
    for case in cases {
        var schedule = rng { seed + (case as u64) };
        var rx:   u8[133] = [0; 133];
        var tx:   u8[131] = [0; 131];
        var sink: u8[145] = [0; 145];
        assert(rx.len == stream::rx_capacity_for(128));
        var rs = 0;
        var re = 0;
        var ts = 0;
        var te = 0;
        var read = 0;
        var sent = 0;
        var packet = 0;
        var turns = 0;
        var idle = 0;
        while sent < wire.len {
            turns += 1;
            assert(turns <= 4 * wire.len);
            let read_cap = schedule.rand_int(17);
            let write_cap = schedule.rand_int(6);
            let before = read + offsets[packet] + sent;
            if read < wire.len {
                let status, s, e, n = stream::feed(rx, rs, re, wire[read..], read_cap);
                if read_cap == 0 {
                    assert(status == stream::WAIT && s == rs && e == re && n == 0);
                    rx_wait += 1;
                } else if rs == 0 && re == rx.len {
                    assert(status == stream::NO_SPACE && s == rs && e == re && n == 0);
                } else {
                    assert(status == stream::OK && n > 0);
                    var append_at = re;
                    if re == rx.len {
                        append_at -= rs;
                        assert(s == 0);
                        rx_compact += 1;
                    } else {
                        assert(s == rs);
                    }
                    assert(e == append_at + n);
                    assert(n == min(min(read_cap, wire.len - read), rx.len - append_at));
                }
                rs = s;
                re = e;
                read += n;
            }
            let framed = offsets[packet];
            assert(rs >= 0 && re <= rx.len && re - rs == read - framed);
            eq_prefix(rx[rs..re], wire[framed..read]);
            peak_rx = max(peak_rx, re - rs);
            if framed < read {
                let next = offsets[packet + 1];
                let status, used = honkmqtt::frame(rx[rs..re], 128);
                if read < next {
                    assert(status == honkmqtt::INCOMPLETE && used == 0);
                    incomplete += 1;
                } else {
                    assert(status == honkmqtt::OK && used == next - framed);
                    let queued, s, e = stream::enqueue(tx, ts, te, rx[rs..rs + used]);
                    if used > tx.len - (te - ts) {
                        assert(queued == stream::NO_SPACE && s == ts && e == te);
                        tx_blocked += 1;
                    } else {
                        assert(queued == stream::OK);
                        if used > tx.len - te {
                            assert(s == 0 && e == te - ts + used);
                            tx_compact += 1;
                        } else {
                            assert(s == ts && e == te + used);
                        }
                        ts = s;
                        te = e;
                        let committed, ns, ne = stream::commit_rx(rs, re, used);
                        assert(committed == stream::OK && ns == rs + used && ne == re);
                        rs = ns;
                        packet += 1;
                    }
                }
            }
            assert(re - rs == read - offsets[packet]);
            assert(ts >= 0 && te <= tx.len && te - ts == offsets[packet] - sent);
            eq_prefix(tx[ts..te], wire[sent..offsets[packet]]);
            peak_tx = max(peak_tx, te - ts);
            let write, n = stream::drain(ts, te, write_cap);
            assert(n == min(write_cap, te - ts));
            if n == 0 {
                assert(write == stream::WAIT);
                if te > ts { tx_wait += 1; }
            } else {
                assert(write == stream::OK);
                if n < te - ts { tx_short += 1; }
                for i in n { sink[sent + i] = tx[ts + i]; }
                let committed, s, e = stream::commit_tx(ts, te, n);
                assert(committed == stream::OK && s == ts + n && e == te);
                ts = s;
                sent += n;
            }
            if before == read + offsets[packet] + sent {
                idle += 1;
                assert(idle <= 16);
                peak_idle = max(peak_idle, idle);
            } else {
                idle = 0;
            }
        }
        assert(read == wire.len && packet == offsets.len - 1 && rs == re && ts == te);
        eq_prefix(sink, wire);
        peak_turns = max(peak_turns, turns);
    }
    print("Transport replay seed=", seed, " cases=", cases, " frames=", cases * (offsets.len - 1),
          " bytes=", cases * wire.len, " peak_rx=", peak_rx, " peak_tx=", peak_tx,
          " peak_turns=", peak_turns, " peak_idle=", peak_idle);
    print("Transport replay incomplete=", incomplete, " rx_wait=", rx_wait, " rx_compact=", rx_compact,
          " tx_blocked=", tx_blocked, " tx_wait=", tx_wait, " tx_short=", tx_short, " tx_compact=", tx_compact);
    assert(incomplete > 0 && rx_wait > 0 && rx_compact > 0);
    assert(tx_blocked > 0 && tx_wait > 0 && tx_short > 0 && tx_compact > 0);
    assert(peak_rx >= 131 && peak_tx == 131);
}

fn main() {
    capacity_contract();
    feed_short_and_wait();
    fragmented_multibyte_header();
    adjacent_packets();
    eof_incomplete_vs_complete();
    fatal_framing_stops();
    rx_backpressure_and_compact();
    feed_after_empty_window_at_capacity();
    feed_free_tail_before_compact();
    coalesced_frames_before_eof();
    short_writes_commit_only();
    enqueue_compact_with_partly_free_tail();
    malformed_length_window_contracts();
    seeded_varied_valid_sequences();
    seeded_transport_replay();
    print("Transport adapter tests passed");
}
