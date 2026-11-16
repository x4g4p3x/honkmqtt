// Optimized-build PUBLISH parse workload with runtime-varying cases.
// Times the steady-state loop only. Cases are copied into a mutable buffer
// each iteration (salt-touched) so a constant packet cannot be parsed once
// and reused. Expected fields are validated independently before timing.
import honkmqtt from "..";
import std;
import os;

const DEFAULT_ITERS = 1000000;
const CASES = 4;
const MAX_PKT = 16;

// Load case `which % CASES` into buf. Returns packet length, max_body, and the
// independent expected publish fields (used, topic, len, payload, id).
fn load_case(buf: u8[:], which: i64) -> i64, i64, i64, i64, i64, i64, i64 {
    let c = which - (which / CASES) * CASES;
    if c == 0 {
        // QoS 0, topic a/b, 3-byte binary payload; trailing bytes ignored.
        let p: u8[10] = [0x30, 0x08, 0, 3, 'a', '/', 'b', 0, 0xff, 7];
        for i in 10 { buf[i] = p[i]; }
        return 10, 8, 10, 4, 3, 7, 0;
    }
    if c == 1 {
        // QoS 1, topic x, id 0x1234, empty payload.
        let p: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
        for i in 7 { buf[i] = p[i]; }
        return 7, 5, 7, 4, 1, 7, 0x1234;
    }
    if c == 2 {
        // QoS 2 + RETAIN + DUP, topic x, id 0xffff, empty payload.
        let p: u8[7] = [0x3d, 5, 0, 1, 'x', 0xff, 0xff];
        for i in 7 { buf[i] = p[i]; }
        return 7, 5, 7, 4, 1, 7, 65535;
    }
    // QoS 0, topic "yz", empty payload.
    let p: u8[6] = [0x30, 4, 0, 2, 'y', 'z'];
    for i in 6 { buf[i] = p[i]; }
    return 6, 4, 6, 4, 2, 6, 0;
}

fn contribution(used: i64, topic: i64, len: i64, payload: i64, id: i64) -> i64 {
    return used + topic + len + payload + id;
}

fn expected_total(iters: i64) -> i64 {
    // Independent of the timed path: sum each case contribution * floor(iters/CASES),
    // then add the prefix of the cycle for iters % CASES.
    let per: i64[4] = [
        contribution(10, 4, 3, 7, 0),
        contribution(7, 4, 1, 7, 0x1234),
        contribution(7, 4, 1, 7, 65535),
        contribution(6, 4, 2, 6, 0),
    ];
    var cycle = 0;
    for c in CASES { cycle += per[c]; }
    let full = iters / CASES;
    var total = full * cycle;
    let rem = iters - full * CASES;
    for c in rem { total += per[c]; }
    return total;
}

// Undoable salt so the buffer contents are data-dependent on the iteration
// before parsing, without changing the MQTT meaning.
fn salt_packet(buf: u8[:], n: i64, salt: i64) {
    let b = (salt % 251) as u8;
    buf[0] = buf[0] ^ b;
    buf[0] = buf[0] ^ b;
    if n > 1 {
        let c = ((salt / 251) % 251) as u8;
        buf[n - 1] = buf[n - 1] ^ c;
        buf[n - 1] = buf[n - 1] ^ c;
    }
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

    // Independent correctness: every case must match the expected wire fields.
    for c in CASES {
        let n, max_body, eu, et, el, ep, eid = load_case(buf, c);
        let status, used, topic, len, payload, id = honkmqtt::publish(buf[0..n], max_body);
        assert(status == honkmqtt::OK);
        assert(used == eu && topic == et && len == el && payload == ep && id == eid);
        assert(buf[topic..topic + len].len == len);
    }

    let expect = expected_total(iters);
    var checksum = 0;
    let t0 = clock();
    for i in iters {
        let n, max_body, eu, et, el, ep, eid = load_case(buf, i);
        salt_packet(buf, n, i + 1);
        let status, used, topic, len, payload, id = honkmqtt::publish(buf[0..n], max_body);
        if status != honkmqtt::OK { abort("publish failed during timed loop"); }
        // Depend on parsed fields and on a byte from the runtime buffer.
        checksum += used + topic + len + payload + id + buf[payload - 1];
        // Keep expected table live so a wrong case selection fails the run.
        if used != eu || topic != et || len != el || payload != ep || id != eid {
            abort("publish fields drifted from independent expectations");
        }
    }
    let elapsed = clock() - t0;
    // Payload-byte term: for each case, buf[payload-1] is the last header/topic
    // or id byte; fold the same values into expect.
    var extra = 0;
    let full = iters / CASES;
    let rem = iters - full * CASES;
    // Bytes at payload-1 for each case: 'b', 0x34, 0xff, 'z'.
    let last: i64[4] = ['b', 0x34, 0xff, 'z'];
    for c in CASES { extra += full * last[c]; }
    for c in rem { extra += last[c]; }
    assert(checksum == expect + extra);

    // Clock resolution probe: minimum positive delta over many reads.
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
