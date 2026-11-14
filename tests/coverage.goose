import honkmqtt from "..";

// Exercise every fixed-header type/flag combination against the MQTT 3.1.1
// table. PUBLISH permits QoS 0 without DUP, and QoS 1 or 2 with either DUP.
fn flags() {
    for byte in 256 {
        let kind = byte / 16;
        let flag = byte % 16;
        var valid = false;
        if kind == 3 {
            valid = flag == 0 || flag == 1 || flag == 2 || flag == 3 || flag == 4 || flag == 5 ||
                    flag == 10 || flag == 11 || flag == 12 || flag == 13;
        } else if kind == 6 || kind == 8 || kind == 10 {
            valid = flag == 2;
        } else if kind > 0 && kind < 15 {
            valid = flag == 0;
        }
        let input: u8[2] = [byte as u8, 0];
        let status, len, body = honkmqtt::header(input);
        if valid { assert(status == honkmqtt::OK && len == 2 && body == 0); }
        else { assert(status == honkmqtt::INVALID && len == 0 && body == 0); }
    }
}

fn lengths() {
    var body:   u8[16384] = [0; 16384];
    var output: u8[16389] = [0; 16389];
    for i in body.len { body[i] = (i % 251) as u8; }
    let sizes:  i64[6] = [0, 1, 127, 128, 16383, 16384];
    let widths: i64[6] = [2, 2, 2, 3, 3, 4];
    for size, k in sizes {
        let expected = size + widths[k];
        let status, written = honkmqtt::encode(0x30, body[0..size], output);
        assert(status == honkmqtt::OK && written == expected);
        let hs, prefix, remaining = honkmqtt::header(output[0..written]);
        assert(hs == honkmqtt::OK && prefix == widths[k] && remaining == size);
        let fs, consumed = honkmqtt::frame(output[0..written], size);
        assert(fs == honkmqtt::OK && consumed == written);
        for i in size { assert(output[prefix + i] == body[i]); }
        let partial, count = honkmqtt::frame(output[0..written - 1], size);
        assert(partial == honkmqtt::INCOMPLETE && count == 0);
    }
}

fn main() {
    flags();
    lengths();
    // MQTT UTF-8 fields have a two-byte length; reject one byte beyond it.
    var long_text: u8[65536] = [0x61; 65536];
    assert(honkmqtt::valid_topic(long_text[0..65535]));
    assert(!honkmqtt::valid_topic(long_text));
    assert(honkmqtt::valid_filter(long_text[0..65535]));
    assert(!honkmqtt::valid_filter(long_text));
    // UTF-8 minima, maxima, overlong encodings and bad continuation bytes.
    assert(honkmqtt::valid_utf8([0xc2, 0x80]));
    assert(honkmqtt::valid_utf8([0xdf, 0xbf]));
    assert(honkmqtt::valid_utf8([0xe0, 0xa0, 0x80]));
    assert(honkmqtt::valid_utf8([0xef, 0xbf, 0xbf]));
    assert(honkmqtt::valid_utf8([0xf0, 0x90, 0x80, 0x80]));
    assert(!honkmqtt::valid_utf8([0xf0, 0x80, 0x80, 0x80]));
    assert(!honkmqtt::valid_utf8([0xe1, 0x7f, 0x80]));
    assert(!honkmqtt::valid_utf8([0xf5, 0x80, 0x80, 0x80]));
    assert(!honkmqtt::valid_utf8([0xc2]));
    assert(!honkmqtt::valid_utf8([0xf0, 0x90, 0x80]));
    assert(!honkmqtt::valid_filter(""));
    assert(!honkmqtt::valid_filter("#foo"));
    assert(!honkmqtt::valid_filter("a+"));
    assert(honkmqtt::valid_filter("/+/"));
    assert(honkmqtt::matches("/+/", "//"));
    assert(honkmqtt::matches("a/#", "a/b/c"));
    assert(!honkmqtt::matches("a/b", "a/c"));
    print("Coverage cases passed");
}
