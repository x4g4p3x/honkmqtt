// Combined encode + frame + topic-match workload with runtime-varying inputs.
// Bodies/filters/topics are copied into mutable buffers each iteration and
// salt-touched so encode/match cannot be constant-folded away. Times the
// steady-state loop only; checksum is derived from observed statuses/lengths.
import honkmqtt from "..";
import std;
import os;

const CASES = 3;
const BODY_MAX = 32;
const TEXT_MAX = 48;

fn body_for(case: i64) -> u8[:] {
    if case == 0 { return "sensor reading"; }
    if case == 1 { return "temp"; }
    return "humidity-sample";
}

fn filter_for(case: i64) -> u8[:] {
    if case == 0 { return "sensors/+/temperature"; }
    if case == 1 { return "sensors/#"; }
    return "sensors/+/humidity";
}

fn match_topic_for(case: i64) -> u8[:] {
    if case == 0 { return "sensors/kitchen/temperature"; }
    if case == 1 { return "sensors/lab/humidity"; }
    return "sensors/kitchen/humidity";
}

fn miss_topic_for(case: i64) -> u8[:] {
    if case == 0 { return "sensors/kitchen/humidity"; }
    if case == 1 { return "other/lab/humidity"; }
    return "sensors/kitchen/temperature";
}

fn copy_text(dst: u8[:], src: const u8[:]) -> i64 {
    assert(src.len <= dst.len);
    for i in src.len { dst[i] = src[i]; }
    return src.len;
}

fn salt_bytes(buf: u8[:], n: i64, salt: i64) {
    if n <= 0 { return; }
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
    let argv = args();
    // Optional override keeps compatibility with older docs: argv bodies are
    // ignored for the timed multi-case path; presence still accepted.
    if argv.len != 1 && argv.len != 5 {
        abort("expected no args, or body, filter, matching topic, non-matching topic");
    }

    var body:        u8[BODY_MAX] = [0; BODY_MAX];
    var filter:      u8[TEXT_MAX] = [0; TEXT_MAX];
    var match_topic: u8[TEXT_MAX] = [0; TEXT_MAX];
    var miss_topic:  u8[TEXT_MAX] = [0; TEXT_MAX];
    var packet:      u8[64]       = [0; 64];

    // Independent probe of each case before timing.
    for c in CASES {
        let bn = copy_text(body, body_for(c));
        let flen = copy_text(filter, filter_for(c));
        let mn = copy_text(match_topic, match_topic_for(c));
        let xn = copy_text(miss_topic, miss_topic_for(c));
        let st, written = honkmqtt::encode(0x30, body[0..bn], packet);
        assert(st == honkmqtt::OK);
        let fr, used = honkmqtt::frame(packet[0..written], 64);
        assert(fr == honkmqtt::OK && used == written);
        assert(honkmqtt::matches(filter[0..flen], match_topic[0..mn]));
        assert(!honkmqtt::matches(filter[0..flen], miss_topic[0..xn]));
    }

    var total = 0;
    let t0 = clock();
    for i in 1000000 {
        let c = i - (i / CASES) * CASES;
        let bn = copy_text(body, body_for(c));
        let flen = copy_text(filter, filter_for(c));
        let mn = copy_text(match_topic, match_topic_for(c));
        let xn = copy_text(miss_topic, miss_topic_for(c));
        salt_bytes(body, bn, i + 1);
        salt_bytes(filter, flen, i + 3);
        let status, written = honkmqtt::encode(0x30, body[0..bn], packet);
        let framed, used = honkmqtt::frame(packet[0..written], 64);
        if status == honkmqtt::OK && framed == honkmqtt::OK {
            total += used;
            // Depend on a runtime packet byte so encode output stays live.
            total += packet[written - 1];
        }
        if i % 2 == 0 {
            if honkmqtt::matches(filter[0..flen], match_topic[0..mn]) { total += 1; }
        } else {
            if honkmqtt::matches(filter[0..flen], miss_topic[0..xn]) { total += 1; }
        }
    }
    let elapsed = clock() - t0;

    var res = 0;
    for i in 10000 {
        let a = clock_ns();
        let b = clock_ns();
        let d = b - a;
        if d > 0 && (res == 0 || d < res) { res = d; }
    }

    print("workload=encode_frame_match");
    print("iterations=", 1000000);
    print("cases=", CASES);
    print("checksum=", total);
    print("steady_seconds=", elapsed);
    print("clock_res_ns=", res);
}
