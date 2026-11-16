// Optimized-build PUBLISH parse workload. Times the steady-state loop only
// (excludes process startup). Verify the checksum; compare repeated samples
// externally. Default one million iterations; override with -- <iterations>.
import honkmqtt from "..";
import std;
import os;

const DEFAULT_ITERS = 1000000;

fn main() {
    var iters = DEFAULT_ITERS;
    let argv = args();
    if argv.len >= 2 {
        let value, ok = parse_int(argv[1]);
        assert(ok && value > 0);
        iters = value;
    }
    if argv.len > 2 { abort("usage: goose tests/bench_publish.goose -- [iterations]"); }

    // Independent QoS 1 PUBLISH wire vector: topic "x", id 0x1234, empty payload.
    let packet: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
    // Correctness probe before timing.
    let ps, pu, pt, pl, pp, pi = honkmqtt::publish(packet, 5);
    assert(ps == honkmqtt::OK && pu == 7 && pt == 4 && pl == 1 && pp == 7 && pi == 0x1234);

    var checksum = 0;
    let t0 = clock();
    for i in iters {
        let status, used, topic, len, payload, id = honkmqtt::publish(packet, 5);
        if status != honkmqtt::OK { abort("publish failed during timed loop"); }
        checksum += used + topic + len + payload + id;
    }
    let elapsed = clock() - t0;
    // Expected per-iter contribution: 7+4+1+7+0x1234 = 4679.
    assert(checksum == iters * 4679);
    print("workload=publish_parse");
    print("iterations=", iters);
    print("checksum=", checksum);
    print("steady_seconds=", elapsed);
}
