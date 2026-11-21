// Independent bounded transport-adapter vectors for M3 (example helper).
// Exact wire bytes and ordering are asserted; short I/O is deterministic.
import honkmqtt from "..";
import stream from "../examples/stream";

const RX_CAP = 64;
const TX_CAP = 32;
const MAX_BODY = RX_CAP - stream::HEADER_MAX; // 59

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

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

fn main() {
    capacity_contract();
    feed_short_and_wait();
    fragmented_multibyte_header();
    adjacent_packets();
    eof_incomplete_vs_complete();
    fatal_framing_stops();
    rx_backpressure_and_compact();
    short_writes_commit_only();
    print("Transport adapter tests passed");
}
