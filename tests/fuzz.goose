// Reproducible randomized MQTT framing/topic smoke campaign.
// Default: goose tests/fuzz.goose
// Override: goose tests/fuzz.goose -- <seed> <cases>
// This is a minimum smoke campaign with recorded seeds, not a fuzzer safety
// guarantee, AFL/libFuzzer replacement, or protocol conformance suite.
import honkmqtt from "..";
import std;
import os;

const DEFAULT_SEED: u64 = 20261116;
const DEFAULT_CASES = 10000;
const BUF = 48;

fn check_header(input: const u8[:]) {
    let status, prefix, body = honkmqtt::header(input);
    if status == honkmqtt::OK {
        assert(prefix >= 2 && prefix <= 5 && prefix <= input.len);
        assert(body >= 0 && body <= honkmqtt::MAX_REMAINING);
    } else {
        assert(prefix == 0 && body == 0);
        assert(status == honkmqtt::INCOMPLETE || status == honkmqtt::INVALID);
    }
}

fn check_frame(input: const u8[:], max_body: i64) {
    let status, used = honkmqtt::frame(input, max_body);
    if status == honkmqtt::OK {
        assert(used >= 2 && used <= input.len);
    } else {
        assert(used == 0);
        assert(
            status == honkmqtt::INCOMPLETE ||
            status == honkmqtt::INVALID,
        );
    }
}

fn check_publish(input: const u8[:], max_body: i64) {
    let status, used, topic, len, payload, id = honkmqtt::publish(input, max_body);
    if status == honkmqtt::OK {
        assert(used >= 4 && used <= input.len);
        assert(topic >= 0 && len >= 0 && topic + len <= used);
        assert(payload >= topic + len && payload <= used);
        let qos = (input[0] / 2) % 4;
        if qos == 0 { assert(id == 0); }
        else { assert(id >= 1 && id <= 65535); }
        assert(honkmqtt::valid_topic(input[topic..topic + len]));
    } else {
        assert(used == 0 && topic == 0 && len == 0 && payload == 0 && id == 0);
        assert(
            status == honkmqtt::INCOMPLETE ||
            status == honkmqtt::INVALID,
        );
    }
}

fn check_encode(first: u8, body: const u8[:], out: u8[:], fill: u8) {
    for i in out.len { out[i] = fill; }
    let status, written = honkmqtt::encode(first, body, out);
    if status == honkmqtt::OK {
        assert(written >= 2 && written <= out.len);
        assert(out[0] == first);
        check_header(out[0..written]);
        check_frame(out[0..written], body.len);
        for i in body.len { assert(out[written - body.len + i] == body[i]); }
    } else {
        assert(written == 0);
        assert(status == honkmqtt::INVALID || status == honkmqtt::NO_SPACE);
        for i in out.len { assert(out[i] == fill); }
    }
}

// Saved regressions: fixed vectors kept after interesting failures or audits.
fn saved_regressions() {
    // Truncated two-byte remaining length must not consume.
    check_header([0x30, 0x80]);
    check_frame([0x30, 0x80], 128);
    check_publish([0x30, 0x80], 128);
    // Non-minimal remaining length is INVALID with zero outs.
    check_header([0x30, 0x80, 0x00]);
    check_frame([0x30, 0x80, 0x00], 128);
    check_publish([0x30, 0x80, 0x00], 128);
    // Adjacent PINGREQ must not be absorbed into a short PUBLISH parse.
    let adj: u8[6] = [0x30, 2, 0, 0, 0xc0, 0];
    check_publish(adj, 10);
    // Wildcard-only filter vs $-topic rule.
    assert(!honkmqtt::matches("#", "$SYS"));
    assert(!honkmqtt::matches("+", "$x"));
    // Encode failure leaves the caller buffer unchanged.
    var sink: u8[2] = [0x11, 0x22];
    check_encode(0x81, "", sink, 0x11);
}

// Deterministic generated malformed/boundary inputs (lengths, flags, UTF-8,
// wildcards, truncation) before the randomized campaign.
fn deterministic_generated() {
    for byte in 256 {
        let input: u8[2] = [byte as u8, 0];
        check_header(input);
        check_frame(input, 0);
        check_publish(input, 0);
    }
    // Truncation ladders for one-, two-, and three-byte remaining lengths.
    let one: u8[3] = [0x30, 1, 0x61];
    for n in 4 { check_frame(one[0..n], 1); check_publish(one[0..n], 1); }
    let two: u8[5] = [0x30, 0x80, 1, 0, 0];
    for n in 6 { check_header(two[0..n]); check_frame(two[0..n], 128); }
    let three: u8[6] = [0x30, 0x80, 0x80, 1, 0, 0];
    for n in 7 { check_header(three[0..n]); }
    // UTF-8 and wildcard boundaries.
    assert(honkmqtt::valid_utf8(""));
    assert(!honkmqtt::valid_utf8([0xed, 0xa0, 0x80]));
    assert(!honkmqtt::valid_topic("a#"));
    assert(!honkmqtt::valid_filter("a#b"));
    assert(honkmqtt::valid_filter("a/+/b/#"));
    assert(honkmqtt::matches("a/+/b/#", "a/x/b/c"));
    assert(!honkmqtt::matches("a/+/b/#", "a/x/c/c"));
}

fn fill(buf: u8[:], r: rng&) {
    for i in buf.len { buf[i] = r.rand_int(256) as u8; }
}

fn random_campaign(seed: u64, cases: i64) {
    var r = rng { seed };
    var buf:    u8[BUF]     = [0; BUF];
    var out:    u8[BUF + 5] = [0; BUF + 5];
    var body:   u8[16]      = [0; 16];
    var text_a: u8[16]      = [0; 16];
    var text_b: u8[16]      = [0; 16];
    for case in cases {
        let n = r.rand_int(BUF + 1);
        fill(buf[0..n], r);
        check_header(buf[0..n]);
        let max_body = r.rand_int(BUF + 2) - 1; // may be -1
        check_frame(buf[0..n], max_body);
        check_publish(buf[0..n], max_body);

        let body_n = r.rand_int(17);
        fill(body[0..body_n], r);
        check_encode(r.rand_int(256) as u8, body[0..body_n], out, 0xa5);

        let a_n = r.rand_int(17);
        let b_n = r.rand_int(17);
        fill(text_a[0..a_n], r);
        fill(text_b[0..b_n], r);
        // Prefer printable ASCII often enough to exercise topic/filter paths.
        if r.rand_int(2) == 0 {
            for i in a_n { text_a[i] = (32 + r.rand_int(95)) as u8; }
            for i in b_n { text_b[i] = (32 + r.rand_int(95)) as u8; }
        }
        let _u = honkmqtt::valid_utf8(text_a[0..a_n]);
        let _t = honkmqtt::valid_topic(text_a[0..a_n]);
        let _f = honkmqtt::valid_filter(text_a[0..a_n]);
        let _m = honkmqtt::matches(text_a[0..a_n], text_b[0..b_n]);
        // Keep the draws used so the compiler cannot drop the checks.
        if _u && _t && _f && _m { assert(a_n >= 0 && b_n >= 0); }
        // Case index is available for bisecting a failing seed.
        if case < 0 { abort("unreachable"); }
    }
}

fn main() {
    var seed = DEFAULT_SEED;
    var cases = DEFAULT_CASES;
    let argv = args();
    if argv.len >= 2 {
        let value, ok = parse_uint(argv[1]);
        assert(ok);
        seed = value;
    }
    if argv.len >= 3 {
        let value, ok = parse_int(argv[2]);
        assert(ok && value >= DEFAULT_CASES);
        cases = value;
    }
    if argv.len > 3 { abort("usage: goose tests/fuzz.goose -- [seed] [cases>=10000]"); }

    saved_regressions();
    deterministic_generated();
    random_campaign(seed, cases);
    print("Fuzz smoke passed: seed=", seed, " cases=", cases);
}
