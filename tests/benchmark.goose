// Combined encode + frame + topic-match workload with runtime-varying inputs.
// Bodies and match-topic segments are mutated from the loop index each
// iteration so encode/match cannot treat inputs as compile-time constants.
// Times the steady-state loop only; checksum is derived from observed outputs.
import honkmqtt from "..";
import std;
import os;

const CASES = 3;
const BODY_MAX = 32;
const TEXT_MAX = 48;
const ITERS = 1000000;

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

// Mutate the last body byte from the loop index (valid opaque body).
fn mutate_body(body: u8[:], n: i64, salt: i64) -> i64 {
    assert(n > 0);
    let b = salt - (salt / 251) * 251;
    body[n - 1] = b as u8;
    return b;
}

// Mutate the first character of the second topic level; still matches `+` / `#`.
fn mutate_match_topic(topic: u8[:], n: i64, case: i64, salt: i64) -> i64 {
    // "sensors/X/..." -> index 8 is the first char of level 2 for these cases.
    assert(n > 8);
    let ch = 'a' + (salt - (salt / 26) * 26);
    topic[8] = ch as u8;
    return ch;
}

fn expected_total(iters: i64) -> i64 {
    // Independent of timed encode/frame/match calls: same mutations and lengths.
    var body: u8[BODY_MAX] = [0; BODY_MAX];
    var total = 0;
    for i in iters {
        let c = i - (i / CASES) * CASES;
        let bn = copy_text(body, body_for(c));
        let live = mutate_body(body, bn, i + 1);
        // used = 2 + bn for these short bodies; last encoded byte == live.
        total += (2 + bn) + live;
        if i % 2 == 0 {
            total += 1; // match path succeeds after mutation
        }
    }
    return total;
}

fn main() {
    let argv = args();
    if argv.len != 1 {
        abort("encode_frame_match takes no arguments (legacy body/filter/topic argv rejected)");
    }

    var body:        u8[BODY_MAX] = [0; BODY_MAX];
    var filter:      u8[TEXT_MAX] = [0; TEXT_MAX];
    var match_topic: u8[TEXT_MAX] = [0; TEXT_MAX];
    var miss_topic:  u8[TEXT_MAX] = [0; TEXT_MAX];
    var packet:      u8[64]       = [0; 64];

    // Independent probe of each case before timing (with a sample mutation).
    for c in CASES {
        let bn = copy_text(body, body_for(c));
        let flen = copy_text(filter, filter_for(c));
        let mn = copy_text(match_topic, match_topic_for(c));
        let xn = copy_text(miss_topic, miss_topic_for(c));
        mutate_body(body, bn, c + 1);
        mutate_match_topic(match_topic, mn, c, c + 1);
        let st, written = honkmqtt::encode(0x30, body[0..bn], packet);
        assert(st == honkmqtt::OK);
        let fr, used = honkmqtt::frame(packet[0..written], 64);
        assert(fr == honkmqtt::OK && used == written);
        assert(honkmqtt::matches(filter[0..flen], match_topic[0..mn]));
        assert(!honkmqtt::matches(filter[0..flen], miss_topic[0..xn]));
    }

    let expect = expected_total(ITERS);
    var total = 0;
    let t0 = clock();
    for i in ITERS {
        let c = i - (i / CASES) * CASES;
        let bn = copy_text(body, body_for(c));
        let flen = copy_text(filter, filter_for(c));
        let mn = copy_text(match_topic, match_topic_for(c));
        let xn = copy_text(miss_topic, miss_topic_for(c));
        let live = mutate_body(body, bn, i + 1);
        mutate_match_topic(match_topic, mn, c, i + 1);
        let status, written = honkmqtt::encode(0x30, body[0..bn], packet);
        let framed, used = honkmqtt::frame(packet[0..written], 64);
        if status == honkmqtt::OK && framed == honkmqtt::OK {
            total += used;
            total += packet[written - 1];
            if packet[written - 1] != live {
                abort("encoded body byte drifted from runtime mutation");
            }
        } else {
            abort("encode/frame failed during timed loop");
        }
        if i % 2 == 0 {
            if honkmqtt::matches(filter[0..flen], match_topic[0..mn]) { total += 1; }
            else { abort("expected match after runtime topic mutation"); }
        } else {
            if honkmqtt::matches(filter[0..flen], miss_topic[0..xn]) { total += 1; }
        }
    }
    let elapsed = clock() - t0;
    assert(total == expect);

    var res = 0;
    for i in 10000 {
        let a = clock_ns();
        let b = clock_ns();
        let d = b - a;
        if d > 0 && (res == 0 || d < res) { res = d; }
    }

    print("workload=encode_frame_match");
    print("iterations=", ITERS);
    print("cases=", CASES);
    print("checksum=", total);
    print("steady_seconds=", elapsed);
    print("clock_res_ns=", res);
}
