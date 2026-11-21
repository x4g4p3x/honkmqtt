namespace stream;

// Bounded byte-stream adapter for caller-owned RX/TX buffers.
// HonkMQTT stays transport-independent: this package does not import or own
// the codec. Callers apply `honkmqtt::frame` (or typed parsers) to `rx[0..rx_len]`
// with their own `max_body`. Documented contract:
//
//   RX capacity must be at least max_body + HEADER_MAX (5) so one complete
//   MQTT fixed header plus the permitted body can sit in RX at once.
//   TX capacity bounds how much outbound data may be queued before backpressure.
//
// Short I/O is modeled by `max_n` on feed/drain. Zero progress returns WAIT and
// leaves buffers unchanged so callers can park without spinning.

const OK = 0;
const WAIT = 1;        // zero bytes transferred this call; state retained
const NO_SPACE = 2;    // RX full for feed, or TX cannot take whole enqueue
const CLOSED = 3;      // clean peer EOF with empty RX
const TRUNCATED = 4;   // peer EOF with leftover incomplete RX bytes
const INVALID = 5;     // bad arguments (negative lengths/limits)

const HEADER_MAX = 5;

fn rx_free(rx_cap: i64, rx_len: i64) -> i64 {
    if rx_len < 0 || rx_cap < rx_len { return 0; }
    return rx_cap - rx_len;
}

fn tx_free(tx_cap: i64, tx_len: i64) -> i64 {
    if tx_len < 0 || tx_cap < tx_len { return 0; }
    return tx_cap - tx_len;
}

// Append up to `max_n` bytes from `src` into `rx` starting at `rx_len`.
// Returns (status, new_rx_len, taken).
//   WAIT — max_n == 0 or src empty (or both); buffers unchanged, taken 0
//   NO_SPACE — RX has no free byte and src is nonempty with max_n > 0
//   OK — took one or more bytes (may be short relative to src)
//   INVALID — negative rx_len/max_n or rx_len > rx.len
fn feed(rx: u8[:], rx_len: i64, src: const u8[:], max_n: i64) -> i64, i64, i64 {
    if rx_len < 0 || max_n < 0 || rx_len > rx.len { return INVALID, rx_len, 0; }
    if max_n == 0 || src.len == 0 { return WAIT, rx_len, 0; }
    let free = rx.len - rx_len;
    if free == 0 { return NO_SPACE, rx_len, 0; }
    var take = max_n;
    if take > free { take = free; }
    if take > src.len { take = src.len; }
    for i in take { rx[rx_len + i] = src[i]; }
    return OK, rx_len + take, take;
}

// Remove `n` leading bytes from RX after a complete frame was handled.
// Returns (status, new_rx_len). INVALID if n out of range.
fn shift_rx(rx: u8[:], rx_len: i64, n: i64) -> i64, i64 {
    if rx_len < 0 || n < 0 || n > rx_len || rx_len > rx.len { return INVALID, rx_len; }
    var i = 0;
    while i < rx_len - n {
        rx[i] = rx[n + i];
        i += 1;
    }
    return OK, rx_len - n;
}

// Queue an entire packet into TX, or take nothing (atomic enqueue).
// Returns (status, new_tx_len).
//   NO_SPACE — packet does not fit in remaining TX capacity
//   OK — packet copied; new length is previous + packet.len
//   INVALID — bad lengths
fn enqueue(tx: u8[:], tx_len: i64, packet: const u8[:]) -> i64, i64 {
    if tx_len < 0 || tx_len > tx.len { return INVALID, tx_len; }
    if packet.len > tx.len - tx_len { return NO_SPACE, tx_len; }
    for i in packet.len { tx[tx_len + i] = packet[i]; }
    return OK, tx_len + packet.len;
}

// Report how many leading TX bytes may be written this turn (short-write cap).
// Returns (status, n). Does not mutate TX; pair with `shift_tx` after a real write.
//   WAIT — max_n == 0 or TX empty
//   OK — n = min(tx_len, max_n) > 0
//   INVALID — bad lengths
fn drain(tx_len: i64, max_n: i64) -> i64, i64 {
    if tx_len < 0 || max_n < 0 { return INVALID, 0; }
    if max_n == 0 || tx_len == 0 { return WAIT, 0; }
    var n = max_n;
    if n > tx_len { n = tx_len; }
    return OK, n;
}

// Drop `n` leading TX bytes after a successful short write.
fn shift_tx(tx: u8[:], tx_len: i64, n: i64) -> i64, i64 {
    if tx_len < 0 || n < 0 || n > tx_len || tx_len > tx.len { return INVALID, tx_len; }
    var i = 0;
    while i < tx_len - n {
        tx[i] = tx[n + i];
        i += 1;
    }
    return OK, tx_len - n;
}

// Classify peer EOF relative to residual RX bytes.
fn on_eof(rx_len: i64) -> i64 {
    if rx_len < 0 { return INVALID; }
    if rx_len == 0 { return CLOSED; }
    return TRUNCATED;
}

// Convenience: required RX capacity for a chosen body bound.
fn rx_capacity_for(max_body: i64) -> i64 {
    if max_body < 0 { return -1; }
    return max_body + HEADER_MAX;
}
