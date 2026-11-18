// Opt-in encode_publish Remaining Length boundary stress (MQTT MAX_REMAINING).
// Not part of scripts/test.py: peak heap is ~512 MiB (payload + out).
//
// Expected memory (QoS 0, topic "a"):
//   payload len = MAX_REMAINING - 3 = 268435452 (~256 MiB)
//   out len     = 5 + MAX_REMAINING = 268435460 (~256 MiB)
// Independent OASIS MQTT 3.1.1 §§2.2.3 / 3.3 header for remaining=268435455:
//   first 0x30; Remaining Length VLQ 0xFF 0xFF 0xFF 0x7F; topic len 0x00 0x01; 'a'
//
// Run explicitly:
//   goose tests/publish_encode_maxrl.goose
//   goose --debug tests/publish_encode_maxrl.goose
//   goose build tests/publish_encode_maxrl.goose && ./tests/publish_encode_maxrl
import honkmqtt from "..";

fn fill(buf: u8[:], v: u8) {
    for i in buf.len { buf[i] = v; }
}

fn unchanged(buf: const u8[:], v: u8) {
    for i in buf.len { assert(buf[i] == v); }
}

fn check_header(out: const u8[:]) {
    assert(out[0] == 0x30);
    assert(out[1] == 0xff && out[2] == 0xff && out[3] == 0xff && out[4] == 0x7f);
    assert(out[5] == 0 && out[6] == 1 && out[7] == 'a');
}

fn sample_payload(got: const u8[:], expect_byte: u8) {
    assert(got.len == 268435452);
    assert(got[0] == expect_byte);
    assert(got[got.len / 2] == expect_byte);
    assert(got[got.len - 1] == expect_byte);
}

fn main() {
    let max_rem = honkmqtt::MAX_REMAINING;
    assert(max_rem == 268435455);
    let payload_len = max_rem - 3; // 2-byte topic length + 1-byte topic "a"
    let need = 5 + max_rem;        // 1 fixed + 4 RL digits + remaining

    var payload: u8[>..] = [];
    payload.resize(payload_len, 0x3c);
    var out: u8[>..] = [];
    out.resize(need, 0xa5);

    let st, n = honkmqtt::encode_publish(false, 0, false, "a", 0, payload, out);
    assert(st == honkmqtt::OK && n == need);
    check_header(out);
    assert(out[8..need] == payload);
    for i in need..out.len { assert(out[i] == 0xa5); }
    sample_payload(out[8..need], 0x3c);
    let ps, used, t, tl, p, id = honkmqtt::publish(out[0..n], max_rem);
    assert(ps == honkmqtt::OK && used == n && tl == 1 && id == 0);
    assert(out[t] == 'a' && out[t..t + tl] == "a");
    assert(out[p..used] == payload);

    // Valid maximum size, short out → NO_SPACE (distinguishes from INVALID).
    var short: u8[>..] = [];
    short.resize(need - 1, 0x5a);
    let ns, nn = honkmqtt::encode_publish(false, 0, false, "a", 0, payload, short);
    assert(ns == honkmqtt::NO_SPACE && nn == 0);
    unchanged(short, 0x5a);

    // Remaining Length = MAX_REMAINING + 1 → INVALID; reuse out as sentinel sink.
    // payload.len = (MAX+1) - 3 = MAX_REMAINING - 2.
    payload.resize(max_rem - 2, 0x3c);
    fill(out, 0x5a);
    let bad, bn = honkmqtt::encode_publish(false, 0, false, "a", 0, payload, out);
    assert(bad == honkmqtt::INVALID && bn == 0);
    unchanged(out, 0x5a);

    print("PUBLISH encode MAX_REMAINING tests passed");
}
