namespace stream;

// Example-only bounded byte-stream helper (not a stable HonkMQTT core API).
// Callers own fixed RX/TX storage and apply `honkmqtt::frame` (or typed
// parsers) to the live RX window. Short I/O uses `max_n`; zero progress
// returns WAIT without mutating cursors so callers can park without spinning.
//
// Cursors: pending bytes are buf[start..end). Appends write at `end`.
// `commit_*` advances `start` only (no per-write memmove). `compact` slides
// pending bytes to index 0 when feed/enqueue needs more tail room: `feed`
// only when `end == rx.len` but `start > 0`; `enqueue` whenever
// `packet.len > tx.len - end` yet total free capacity can hold the packet
// (even if some unused tail bytes remain).
//
// Non-overlap: `src` for `feed` must be disjoint from the entire RX buffer
// (not merely from `rx[end..)`), and `packet` for `enqueue` must be disjoint
// from the entire TX buffer. Compaction may overwrite `buf[0..start)` before
// reading the source, so a view into the consumed head can be corrupted even
// when it does not overlap the eventual append range.
//
// RX frame views: `rx[start..end)` (and any slice into it) is valid only until
// the next `feed`/`commit_rx`/`compact` that changes start/end or moves bytes.
// Copy or finish parsing before those calls.
//
// Capacity: RX should be at least max_body + HEADER_MAX so one permitted frame
// can sit in the window. TX capacity bounds queued outbound bytes.

const OK = 0;
const WAIT = 1;        // zero bytes this call; cursors retained
const NO_SPACE = 2;    // cannot accept more without consuming / larger buffer
const CLOSED = 3;      // peer EOF with empty RX window
const TRUNCATED = 4;   // peer EOF with leftover incomplete RX bytes
const INVALID = 5;     // bad arguments

const HEADER_MAX = 5;
// MQTT Remaining Length maximum; used only to bound capacity arithmetic.
const MAX_BODY = 268435455;

fn pending(start: i64, end: i64) -> i64 {
    if start < 0 || end < start { return -1; }
    return end - start;
}

fn rx_capacity_for(max_body: i64) -> i64 {
    if max_body < 0 || max_body > MAX_BODY - HEADER_MAX { return -1; }
    return max_body + HEADER_MAX;
}

// Slide buf[start..end) to index 0. Returns (status, new_start=0, new_end).
fn compact(buf: u8[:], start: i64, end: i64) -> i64, i64, i64 {
    if start < 0 || end < start || end > buf.len { return INVALID, start, end; }
    if start == 0 { return OK, 0, end; }
    var i = 0;
    let n = end - start;
    while i < n {
        buf[i] = buf[start + i];
        i += 1;
    }
    return OK, 0, n;
}

// Append up to max_n bytes from src at `end`. Compacts first only if the tail
// is full but pending bytes leave headroom. `src` must be disjoint from `rx`.
// Returns (status, start, end, taken).
fn feed(rx: u8[:], start: i64, end: i64, src: const u8[:], max_n: i64) -> i64, i64, i64, i64 {
    if start < 0 || end < start || end > rx.len || max_n < 0 { return INVALID, start, end, 0; }
    if max_n == 0 || src.len == 0 { return WAIT, start, end, 0; }
    var s = start;
    var e = end;
    if e == rx.len {
        if s == 0 { return NO_SPACE, s, e, 0; }
        let cs, ns, ne = compact(rx, s, e);
        if cs != OK { return cs, start, end, 0; }
        s = ns;
        e = ne;
    }
    let free = rx.len - e;
    if free == 0 { return NO_SPACE, s, e, 0; }
    var take = max_n;
    if take > free { take = free; }
    if take > src.len { take = src.len; }
    for i in take { rx[e + i] = src[i]; }
    return OK, s, e + take, take;
}

// Drop n leading pending RX bytes after a complete frame was handled.
// Advances start only. Returns (status, start, end).
fn commit_rx(start: i64, end: i64, n: i64) -> i64, i64, i64 {
    if start < 0 || end < start || n < 0 || n > end - start { return INVALID, start, end; }
    return OK, start + n, end;
}

// Queue an entire packet at `end`, or take nothing. Compacts when
// `packet.len > tx.len - end` but total free capacity can hold it (unused
// tail bytes may remain). `packet` must be disjoint from `tx`.
// Returns (status, start, end).
fn enqueue(tx: u8[:], start: i64, end: i64, packet: const u8[:]) -> i64, i64, i64 {
    if start < 0 || end < start || end > tx.len { return INVALID, start, end; }
    var s = start;
    var e = end;
    if packet.len > tx.len - e {
        if packet.len > tx.len - (e - s) { return NO_SPACE, start, end; }
        let cs, ns, ne = compact(tx, s, e);
        if cs != OK { return cs, start, end; }
        s = ns;
        e = ne;
        if packet.len > tx.len - e { return NO_SPACE, s, e; }
    }
    for i in packet.len { tx[e + i] = packet[i]; }
    return OK, s, e + packet.len;
}

// How many leading TX bytes may be written this turn (short-write cap).
// Returns (status, n). Bytes are at tx[start..start+n); pair with commit_tx.
fn drain(start: i64, end: i64, max_n: i64) -> i64, i64 {
    if start < 0 || end < start || max_n < 0 { return INVALID, 0; }
    let len = end - start;
    if max_n == 0 || len == 0 { return WAIT, 0; }
    var n = max_n;
    if n > len { n = len; }
    return OK, n;
}

// Advance TX start after a successful short write. No memmove.
fn commit_tx(start: i64, end: i64, n: i64) -> i64, i64, i64 {
    if start < 0 || end < start || n < 0 || n > end - start { return INVALID, start, end; }
    return OK, start + n, end;
}

// After draining complete frames from RX, classify peer EOF.
// Call only when no further complete frame remains in the window.
fn on_eof(pending_len: i64) -> i64 {
    if pending_len < 0 { return INVALID; }
    if pending_len == 0 { return CLOSED; }
    return TRUNCATED;
}
