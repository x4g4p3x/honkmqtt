// Independent bounded transport-adapter vectors for M3.
// Exact wire bytes and ordering are asserted; short I/O is deterministic.
import honkmqtt from "..";
import stream from "../stream";

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

fn try_frame(rx: const u8[:], rx_len: i64) -> i64, i64 {
    return honkmqtt::frame(rx[0..rx_len], MAX_BODY);
}

fn capacity_contract() {
    assert(stream::HEADER_MAX == 5);
    assert(stream::rx_capacity_for(MAX_BODY) == RX_CAP);
    assert(stream::rx_capacity_for(-1) == -1);
}

fn feed_short_and_wait() {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    fill(rx, 0xa5);
    var rx_len = 0;

    // Zero-progress feed: WAIT, RX untouched.
    let w, nl, t = stream::feed(rx, rx_len, [0xc0, 0x00], 0);
    assert(w == stream::WAIT && nl == 0 && t == 0);
    assert(rx[0] == 0xa5);

    // Short read of one byte from a two-byte PINGREQ.
    let s1, n1, t1 = stream::feed(rx, rx_len, [0xc0, 0x00], 1);
    assert(s1 == stream::OK && n1 == 1 && t1 == 1 && rx[0] == 0xc0);
    rx_len = n1;
    let f1, u1 = try_frame(rx, rx_len);
    assert(f1 == honkmqtt::INCOMPLETE && u1 == 0);

    // Second short read completes the frame.
    let s2, n2, t2 = stream::feed(rx, rx_len, [0x00], 1);
    assert(s2 == stream::OK && n2 == 2 && t2 == 1 && rx[1] == 0x00);
    rx_len = n2;
    let f2, u2 = try_frame(rx, rx_len);
    assert(f2 == honkmqtt::OK && u2 == 2);
    eq_prefix(rx[0..u2], [0xc0, 0x00]);

    let cs, n3 = stream::shift_rx(rx, rx_len, u2);
    assert(cs == stream::OK && n3 == 0);
}

fn fragmented_multibyte_header() {
    // Remaining Length 128 → VLQ 0x80 0x01 (two-byte header encoding).
    var body: u8[128] = [0x5a; 128];
    var pkt:  u8[140] = [0; 140];
    let es, en = honkmqtt::encode(0x30, body, pkt); // PUBLISH QoS0
    assert(es == honkmqtt::OK && en == 1 + 2 + 128);
    assert(pkt[0] == 0x30 && pkt[1] == 0x80 && pkt[2] == 0x01);

    var rx: u8[RX_CAP] = [0; RX_CAP];
    // RX_CAP 64 < 131: cannot hold this frame; use max_body that rejects it.
    // Fragment the header only inside a larger temp buffer for the header test.
    var big: u8[160] = [0; 160];
    var bl = 0;
    let s0, n0, t0 = stream::feed(big, bl, pkt[0..1], 1);
    assert(s0 == stream::OK && n0 == 1 && t0 == 1);
    bl = n0;
    let h0, hp0, hb0 = honkmqtt::header(big[0..bl]);
    assert(h0 == honkmqtt::INCOMPLETE && hp0 == 0 && hb0 == 0);

    let s1, n1, t1 = stream::feed(big, bl, pkt[1..2], 1);
    assert(s1 == stream::OK && n1 == 2 && t1 == 1);
    bl = n1;
    let h1, hp1, hb1 = honkmqtt::header(big[0..bl]);
    assert(h1 == honkmqtt::INCOMPLETE && hp1 == 0 && hb1 == 0);

    let s2, n2, t2 = stream::feed(big, bl, pkt[2..3], 1);
    assert(s2 == stream::OK && n2 == 3 && t2 == 1);
    bl = n2;
    let h2, hp, hb = honkmqtt::header(big[0..bl]);
    assert(h2 == honkmqtt::OK && hp == 3 && hb == 128);
    let f2, u2 = honkmqtt::frame(big[0..bl], 128);
    assert(f2 == honkmqtt::INCOMPLETE && u2 == 0);

    // Feed the body in short chunks of 32.
    var off = 3;
    while off < en {
        var chunk = 32;
        if chunk > en - off { chunk = en - off; }
        let fs, fn_, ft = stream::feed(big, bl, pkt[off..off + chunk], chunk);
        assert(fs == stream::OK && ft == chunk);
        bl = fn_;
        off += chunk;
    }
    assert(bl == en);
    let f3, u3 = honkmqtt::frame(big[0..bl], 128);
    assert(f3 == honkmqtt::OK && u3 == en);
    eq_prefix(big[0..3], [0x30, 0x80, 0x01]);
}

fn adjacent_packets() {
    // Independent expected stream: PINGREQ then PINGRESP then DISCONNECT.
    let wire: u8[6] = [0xc0, 0x00, 0xd0, 0x00, 0xe0, 0x00];
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var rx_len = 0;

    // Deliver one byte at a time.
    for i in wire.len {
        let st, nl, t = stream::feed(rx, rx_len, wire[i..i + 1], 1);
        assert(st == stream::OK && t == 1);
        rx_len = nl;
    }
    assert(rx_len == 6);

    let a, ua = try_frame(rx, rx_len);
    assert(a == honkmqtt::OK && ua == 2);
    eq_prefix(rx[0..2], [0xc0, 0x00]);
    let _, r1 = stream::shift_rx(rx, rx_len, ua);
    rx_len = r1;

    let b, ub = try_frame(rx, rx_len);
    assert(b == honkmqtt::OK && ub == 2);
    eq_prefix(rx[0..2], [0xd0, 0x00]);
    let _, r2 = stream::shift_rx(rx, rx_len, ub);
    rx_len = r2;

    let c, uc = try_frame(rx, rx_len);
    assert(c == honkmqtt::OK && uc == 2);
    eq_prefix(rx[0..2], [0xe0, 0x00]);
    let _, r3 = stream::shift_rx(rx, rx_len, uc);
    rx_len = r3;
    assert(rx_len == 0);
}

fn eof_clean_and_truncated() {
    assert(stream::on_eof(0) == stream::CLOSED);
    assert(stream::on_eof(1) == stream::TRUNCATED);

    var rx: u8[RX_CAP] = [0; RX_CAP];
    var rx_len = 0;
    let st, nl, _ = stream::feed(rx, rx_len, [0xc0], 1);
    assert(st == stream::OK);
    rx_len = nl;
    let f, u = try_frame(rx, rx_len);
    assert(f == honkmqtt::INCOMPLETE && u == 0);
    assert(stream::on_eof(rx_len) == stream::TRUNCATED);
}

fn rx_backpressure() {
    var rx: u8[4] = [0; 4];
    var rx_len = 0;
    let s1, n1, t1 = stream::feed(rx, rx_len, [1, 2, 3, 4, 5], 8);
    assert(s1 == stream::OK && n1 == 4 && t1 == 4);
    rx_len = n1;
    // Full RX with more source data → NO_SPACE; bytes retained.
    let s2, n2, t2 = stream::feed(rx, rx_len, [9], 1);
    assert(s2 == stream::NO_SPACE && n2 == 4 && t2 == 0);
    assert(rx[0] == 1 && rx[3] == 4);
}

fn short_writes_and_zero_progress() {
    var tx: u8[TX_CAP] = [0; TX_CAP];
    fill(tx, 0xee);
    var tx_len = 0;

    let ping: u8[2] = [0xc0, 0x00];
    let resp: u8[2] = [0xd0, 0x00];
    let e1, n1 = stream::enqueue(tx, tx_len, ping);
    assert(e1 == stream::OK && n1 == 2);
    tx_len = n1;
    let e2, n2 = stream::enqueue(tx, tx_len, resp);
    assert(e2 == stream::OK && n2 == 4);
    tx_len = n2;
    eq_prefix(tx[0..4], [0xc0, 0x00, 0xd0, 0x00]);

    // Oversize enqueue → NO_SPACE, TX unchanged.
    var big: u8[TX_CAP] = [0x11; TX_CAP];
    let e3, n3 = stream::enqueue(tx, tx_len, big);
    assert(e3 == stream::NO_SPACE && n3 == tx_len);
    eq_prefix(tx[0..4], [0xc0, 0x00, 0xd0, 0x00]);

    // Zero-progress drain.
    let w, wn = stream::drain(tx_len, 0);
    assert(w == stream::WAIT && wn == 0);

    // Short write of one byte; retain remainder.
    let d1, dn1 = stream::drain(tx_len, 1);
    assert(d1 == stream::OK && dn1 == 1);
    assert(tx[0] == 0xc0);
    let _, tlen2 = stream::shift_tx(tx, tx_len, dn1);
    tx_len = tlen2;
    assert(tx_len == 3);
    eq_prefix(tx[0..3], [0x00, 0xd0, 0x00]);

    // Drain the rest in a short write of 2, then 1.
    let d2, dn2 = stream::drain(tx_len, 2);
    assert(d2 == stream::OK && dn2 == 2);
    eq_prefix(tx[0..2], [0x00, 0xd0]);
    let _, tlen3 = stream::shift_tx(tx, tx_len, dn2);
    tx_len = tlen3;
    let d3, dn3 = stream::drain(tx_len, 8);
    assert(d3 == stream::OK && dn3 == 1 && tx[0] == 0x00);
    let _, tlen4 = stream::shift_tx(tx, tx_len, dn3);
    assert(tlen4 == 0);
    let d4, dn4 = stream::drain(tlen4, 1);
    assert(d4 == stream::WAIT && dn4 == 0);
}

fn malformed_frame_retained() {
    // Complete header with reserved type 0 → INVALID; do not consume.
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var rx_len = 0;
    let st, nl, _ = stream::feed(rx, rx_len, [0x00, 0x00], 2);
    assert(st == stream::OK);
    rx_len = nl;
    let f, u = try_frame(rx, rx_len);
    assert(f == honkmqtt::INVALID && u == 0);
    assert(rx_len == 2 && rx[0] == 0x00 && rx[1] == 0x00);
}

fn main() {
    capacity_contract();
    feed_short_and_wait();
    fragmented_multibyte_header();
    adjacent_packets();
    eof_clean_and_truncated();
    rx_backpressure();
    short_writes_and_zero_progress();
    malformed_frame_retained();
    print("Transport adapter tests passed");
}
