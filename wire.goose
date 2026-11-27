namespace honkmqtt;

// Status codes shared by the buffer-oriented API.
const OK = 0;
const INCOMPLETE = 1;
const INVALID = 2;
const NO_SPACE = 3;
const MAX_REMAINING = 268435455;

// Decode one complete fixed header. Returns status, header length, body length.
// An incomplete result consumes nothing; the caller retains and extends the buffer.
fn header(input: const u8[:]) -> i64, i64, i64 {
    if input.len < 1 { return INCOMPLETE, 0, 0; }
    let kind = input[0] / 16;
    let flags = input[0] % 16;
    if kind == 0 || kind == 15 { return INVALID, 0, 0; }
    if kind == 3 {
        let qos = (flags / 2) % 4;
        if qos == 3 || (qos == 0 && flags >= 8) { return INVALID, 0, 0; }
    } else if kind == 6 || kind == 8 || kind == 10 {
        if flags != 2 { return INVALID, 0, 0; }
    } else if flags != 0 { return INVALID, 0, 0; }
    var value = 0;
    var factor = 1;
    for i in 4 {
        if input.len <= i + 1 { return INCOMPLETE, 0, 0; }
        let digit = input[i + 1] as i64;
        value += (digit % 128) * factor;
        if digit < 128 {
            // Reject non-minimal encodings to avoid ambiguous framing.
            if i > 0 && digit == 0 { return INVALID, 0, 0; }
            return OK, i + 2, value;
        }
        factor *= 128;
    }
    return INVALID, 0, 0;
}

// Decode the first frame, without copying. Its bytes are input[0..consumed].
// max_body bounds memory committed by the transport; negative values are invalid.
fn frame(input: const u8[:], max_body: i64) -> i64, i64 {
    if max_body < 0 { return INVALID, 0; }
    let status, prefix, body = header(input);
    if status != OK { return status, 0; }
    if body > max_body { return INVALID, 0; }
    if input.len - prefix < body { return INCOMPLETE, 0; }
    return OK, prefix + body;
}

// Write a fixed header and opaque body. Returns status and bytes written.
// Output must not overlap body. This checks framing flags, not packet semantics.
fn encode(first: u8, body: const u8[:], out: u8[:]) -> i64, i64 {
    if body.len > MAX_REMAINING { return INVALID, 0; }
    var prefix: u8[5] = [0; 5];
    prefix[0] = first;
    var n = body.len;
    var width = 1;
    loop {
        var digit = n % 128;
        n = n / 128;
        if n > 0 { digit += 128; }
        prefix[width] = digit as u8;
        width += 1;
        if n == 0 { break; }
    }
    let status, _, _ = header(prefix[0..width]);
    if status != OK { return INVALID, 0; }
    if out.len < width + body.len { return NO_SPACE, 0; }
    for i in width { out[i] = prefix[i]; }
    for i in body.len { out[width + i] = body[i]; }
    return OK, width + body.len;
}

// Read a 2-byte big-endian length-prefixed field inside [pos, end).
// On success returns (OK, data_offset, data_length, next_pos). On failure
// returns (INVALID, 0, 0, 0). A length that runs past `end` is INVALID (the
// enclosing Remaining Length is already known to be complete).
fn take_prefixed(input: const u8[:], pos: i64, end: i64) -> i64, i64, i64, i64 {
    if end - pos < 2 { return INVALID, 0, 0, 0; }
    let n = (input[pos] as i64) * 256 + input[pos + 1];
    let start = pos + 2;
    if n > end - start { return INVALID, 0, 0, 0; }
    return OK, start, n, start + n;
}
