// Optimized-build encode_publish workload with runtime-varying cases.
// Times the steady-state loop only. Caller buffers are preallocated; each
// iteration copies case templates then mutates payload/id bytes so inputs are
// not compile-time constants. Expected checksum is independent of
// honkmqtt::encode_publish (geometry + mutations only) before timing.
import honkmqtt from "..";
import std;
import os;

const DEFAULT_ITERS = 1000000;
const CASES = 4;
const TOPIC_MAX = 16;
const PAYLOAD_MAX = 128;
const OUT_MAX = 160;

fn copy_bytes(dst: u8[:], src: const u8[:]) -> i64 {
    assert(src.len <= dst.len);
    for i in src.len { dst[i] = src[i]; }
    return src.len;
}

// Case geometry: returns dup, qos, retain, topic_len, packet_id_hi (0 if QoS0),
// payload_len, expected first header byte, expected encoded length.
fn case_geom(which: i64) -> bool, i64, bool, i64, i64, i64, i64, i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 {
        // QoS 0, topic a/b, 3-byte payload (last byte mutated later).
        return false, 0, false, 3, 0, 3, 0x30, 10;
    }
    if c == 1 {
        // QoS 1, topic x, id 0x12XX (lo mutated), empty payload.
        return false, 1, false, 1, 0x12, 0, 0x32, 7;
    }
    if c == 2 {
        // QoS 2 + DUP, topic x, id 0xFFXX (lo mutated), empty payload.
        return true, 2, false, 1, 0xff, 0, 0x3c, 7;
    }
    // QoS 0 + RETAIN, topic z, 64-byte payload (last byte mutated).
    // remaining=67 → need=2+67=69.
    return false, 0, true, 1, 0, 64, 0x31, 69;
}

fn load_topic(topic: u8[:], which: i64) -> i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 { return copy_bytes(topic, "a/b"); }
    if c == 1 || c == 2 { return copy_bytes(topic, "x"); }
    return copy_bytes(topic, "z");
}

fn load_payload(payload: u8[:], which: i64) -> i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 {
        let p: u8[3] = [0, 0xff, 7];
        return copy_bytes(payload, p);
    }
    if c == 3 {
        for i in 64 { payload[i] = 0x11; }
        return 64;
    }
    return 0;
}

// Mutate loop-index-dependent bytes. Returns packet_id and live byte folded
// into the checksum so the mutation stays observable.
fn mutate_runtime(payload: u8[:], payload_len: i64, which: i64, salt: i64) -> i64, i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 || c == 3 {
        let b = salt - (salt / 251) * 251;
        assert(payload_len > 0);
        payload[payload_len - 1] = b as u8;
        return 0, b;
    }
    let lo = 1 + (salt - (salt / 250) * 250);
    let _, qos, _, _, hi, _, _, _ = case_geom(c);
    assert(qos > 0);
    return (hi * 256) + lo, lo;
}

fn contribution(n: i64, first: i64, last: i64, id: i64, live: i64) -> i64 {
    return n + first + last + id + live;
}

fn expected_total(iters: i64) -> i64 {
    var payload: u8[PAYLOAD_MAX] = [0; PAYLOAD_MAX];
    var total = 0;
    for i in iters {
        let _, qos, _, _, _, plen, first, need = case_geom(i);
        let _ = load_payload(payload, i);
        let id, live = mutate_runtime(payload, plen, i, i + 1);
        // Last encoded byte: payload live for QoS 0 cases; id lo for QoS>0.
        var last = live;
        if qos > 0 { last = id - (id / 256) * 256; }
        total += contribution(need, first, last, id, live);
    }
    return total;
}

fn main() {
    var iters = DEFAULT_ITERS;
    let argv = args();
    if argv.len >= 2 {
        let value, ok = parse_int(argv[1]);
        assert(ok && value > 0);
        iters = value;
    }
    if argv.len > 2 { abort("usage: goose tests/bench_encode_publish.goose -- [iterations]"); }

    var topic:   u8[TOPIC_MAX]   = [0; TOPIC_MAX];
    var payload: u8[PAYLOAD_MAX] = [0; PAYLOAD_MAX];
    var out:     u8[OUT_MAX]     = [0; OUT_MAX];

    // Independent correctness on templates (before bulk timing).
    for c in CASES {
        let dup, qos, retain, _, _, plen, first, need = case_geom(c);
        let tl = load_topic(topic, c);
        let pl = load_payload(payload, c);
        assert(pl == plen);
        let id, live = mutate_runtime(payload, plen, c, c + 1);
        let st, n = honkmqtt::encode_publish(
            dup, qos, retain, topic[0..tl], id, payload[0..pl], out,
        );
        assert(st == honkmqtt::OK && n == need);
        assert(out[0] == first as u8);
        var last = live as u8;
        if qos > 0 { last = (id - (id / 256) * 256) as u8; }
        assert(out[n - 1] == last);
        assert(live >= 0);
    }

    let expect = expected_total(iters);
    var checksum = 0;
    let t0 = clock();
    for i in iters {
        let dup, qos, retain, _, _, plen, first, need = case_geom(i);
        let tl = load_topic(topic, i);
        let pl = load_payload(payload, i);
        let id, live = mutate_runtime(payload, plen, i, i + 1);
        let st, n = honkmqtt::encode_publish(
            dup, qos, retain, topic[0..tl], id, payload[0..pl], out,
        );
        if st != honkmqtt::OK { abort("encode_publish failed during timed loop"); }
        if n != need || out[0] != first as u8 {
            abort("encode_publish drifted from independent expectations");
        }
        var last = out[n - 1] as i64;
        checksum += contribution(n, out[0], last, id, live);
    }
    let elapsed = clock() - t0;
    assert(checksum == expect);

    var res = 0;
    for i in 10000 {
        let a = clock_ns();
        let b = clock_ns();
        let d = b - a;
        if d > 0 && (res == 0 || d < res) { res = d; }
    }

    print("workload=publish_encode");
    print("iterations=", iters);
    print("cases=", CASES);
    print("checksum=", checksum);
    print("steady_seconds=", elapsed);
    print("clock_res_ns=", res);
}
