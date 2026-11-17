// Optimized-build PUBLISH parse workload with runtime-varying cases.
// Times the steady-state loop only. Each iteration copies a case template then
// writes loop-index-dependent bytes into the packet so the timed parse input is
// not a compile-time constant. Expected checksum is computed independently of
// honkmqtt::publish before timing.
import honkmqtt from "..";
import std;
import os;

const DEFAULT_ITERS = 1000000;
const CASES = 4;
const MAX_PKT = 16;

// Load case template `which % CASES` into buf. Returns packet length, max_body,
// and fixed geometry (used, topic, len, payload). Packet id / live bytes come
// from mutate_runtime.
fn load_case(buf: u8[:], which: i64) -> i64, i64, i64, i64, i64, i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 {
        // QoS 0, topic a/b, 3-byte binary payload; last payload byte mutated later.
        let p: u8[10] = [0x30, 0x08, 0, 3, 'a', '/', 'b', 0, 0xff, 7];
        for i in 10 { buf[i] = p[i]; }
        return 10, 8, 10, 4, 3, 7;
    }
    if c == 1 {
        // QoS 1, topic x, id hi=0x12, lo mutated later; empty payload.
        let p: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
        for i in 7 { buf[i] = p[i]; }
        return 7, 5, 7, 4, 1, 7;
    }
    if c == 2 {
        // QoS 2 + RETAIN + DUP, topic x, id hi=0xff, lo mutated later.
        let p: u8[7] = [0x3d, 5, 0, 1, 'x', 0xff, 0xff];
        for i in 7 { buf[i] = p[i]; }
        return 7, 5, 7, 4, 1, 7;
    }
    // QoS 0, topic "y?" with second byte mutated later; empty payload.
    let p: u8[6] = [0x30, 4, 0, 2, 'y', 'z'];
    for i in 6 { buf[i] = p[i]; }
    return 6, 4, 6, 4, 2, 6;
}

// Write loop-index-dependent bytes. Returns expected packet id and a live byte
// that must appear in the checksum (forces the mutated input to stay live).
fn mutate_runtime(buf: u8[:], which: i64, salt: i64) -> i64, i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 {
        let b = salt - (salt / 251) * 251;
        buf[9] = b as u8;
        return 0, b;
    }
    if c == 1 {
        let lo = 1 + (salt - (salt / 250) * 250);
        buf[6] = lo as u8;
        return (0x12 * 256) + lo, lo;
    }
    if c == 2 {
        let lo = 1 + (salt - (salt / 250) * 250);
        buf[6] = lo as u8;
        return (0xff * 256) + lo, lo;
    }
    let ch = 'a' + (salt - (salt / 26) * 26);
    buf[5] = ch as u8;
    return 0, ch;
}

fn contribution(used: i64, topic: i64, len: i64, payload: i64, id: i64, live: i64) -> i64 {
    return used + topic + len + payload + id + live;
}

fn expected_total(iters: i64) -> i64 {
    // Independent of honkmqtt::publish: same load+mutate geometry as the timed path.
    var buf: u8[MAX_PKT] = [0; MAX_PKT];
    var total = 0;
    for i in iters {
        let n, max_body, eu, et, el, ep = load_case(buf, i);
        let eid, live = mutate_runtime(buf, i, i + 1);
        total += contribution(eu, et, el, ep, eid, live);
        assert(n > 0 && max_body > 0);
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
    if argv.len > 2 { abort("usage: goose tests/bench_publish.goose -- [iterations]"); }

    var buf: u8[MAX_PKT] = [0; MAX_PKT];

    // Independent correctness on templates (before runtime mutation).
    for c in CASES {
        let n, max_body, eu, et, el, ep = load_case(buf, c);
        let eid, live = mutate_runtime(buf, c, c + 1);
        let status, used, topic, len, payload, id = honkmqtt::publish(buf[0..n], max_body);
        assert(status == honkmqtt::OK);
        assert(used == eu && topic == et && len == el && payload == ep && id == eid);
        assert(live >= 0);
    }

    let expect = expected_total(iters);
    var checksum = 0;
    let t0 = clock();
    for i in iters {
        let n, max_body, eu, et, el, ep = load_case(buf, i);
        let eid, live = mutate_runtime(buf, i, i + 1);
        let status, used, topic, len, payload, id = honkmqtt::publish(buf[0..n], max_body);
        if status != honkmqtt::OK { abort("publish failed during timed loop"); }
        checksum += used + topic + len + payload + id + live;
        if used != eu || topic != et || len != el || payload != ep || id != eid {
            abort("publish fields drifted from independent expectations");
        }
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

    print("workload=publish_parse");
    print("iterations=", iters);
    print("cases=", CASES);
    print("checksum=", checksum);
    print("steady_seconds=", elapsed);
    print("clock_res_ns=", res);
}
