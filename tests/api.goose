import honkmqtt from "..";

// Behavioral matrix for every public operation and documented failure status.
// This is an explicit API contract suite, not measured source coverage.

fn header_statuses() {
    // OK: CONNECT (type 1) with required zero flags and zero remaining length.
    let ok, hl, bl = honkmqtt::header([0x10, 0]);
    assert(ok == honkmqtt::OK && hl == 2 && bl == 0);
    // INCOMPLETE: no bytes, and truncated remaining-length digit.
    let e, eh, eb = honkmqtt::header("");
    assert(e == honkmqtt::INCOMPLETE && eh == 0 && eb == 0);
    let t, th, tb = honkmqtt::header([0x10]);
    assert(t == honkmqtt::INCOMPLETE && th == 0 && tb == 0);
    // INVALID: reserved type, forbidden flags, non-minimal length.
    let r, rh, rb = honkmqtt::header([0x00, 0]);
    assert(r == honkmqtt::INVALID && rh == 0 && rb == 0);
    let f, fh, fb = honkmqtt::header([0x11, 0]);
    assert(f == honkmqtt::INVALID && fh == 0 && fb == 0);
    let n, nh, nb = honkmqtt::header([0x10, 0x80, 0x00]);
    assert(n == honkmqtt::INVALID && nh == 0 && nb == 0);
}

fn frame_statuses() {
    var out: u8[4] = [0; 4];
    let w, n = honkmqtt::encode(0xc0, "", out);
    assert(w == honkmqtt::OK && n == 2);
    // OK
    let ok, used = honkmqtt::frame(out[0..2], 0);
    assert(ok == honkmqtt::OK && used == 2);
    // INCOMPLETE: truncated after a valid prefix start
    let inc, iu = honkmqtt::frame([0xc0], 0);
    assert(inc == honkmqtt::INCOMPLETE && iu == 0);
    // INVALID: negative max_body, oversize body, reserved header
    let neg, nu = honkmqtt::frame(out[0..2], -1);
    assert(neg == honkmqtt::INVALID && nu == 0);
    let over, ou = honkmqtt::frame([0x30, 1, 0], 0);
    assert(over == honkmqtt::INVALID && ou == 0);
    let bad, bu = honkmqtt::frame([0x00, 0], 10);
    assert(bad == honkmqtt::INVALID && bu == 0);
}

fn encode_statuses() {
    var out: u8[8] = [0; 8];
    // OK: PINGREQ
    let ok, n = honkmqtt::encode(0xc0, "", out);
    assert(ok == honkmqtt::OK && n == 2 && out[0] == 0xc0 && out[1] == 0);
    // INVALID: forbidden fixed-header flags; output unchanged on failure
    var sentinel: u8[4] = [0x5a; 4];
    let inv, iw = honkmqtt::encode(0xc1, "", sentinel);
    assert(inv == honkmqtt::INVALID && iw == 0);
    assert(sentinel[0] == 0x5a && sentinel[1] == 0x5a && sentinel[2] == 0x5a && sentinel[3] == 0x5a);
    // NO_SPACE: exact undersize leaves buffer untouched
    var tiny: u8[1] = [0xee];
    let nos, nw = honkmqtt::encode(0xc0, "", tiny);
    assert(nos == honkmqtt::NO_SPACE && nw == 0 && tiny[0] == 0xee);
    // OK boundary: buffer exactly the encoded size
    var exact: u8[2] = [0; 2];
    let fit, written = honkmqtt::encode(0xc0, "", exact);
    assert(fit == honkmqtt::OK && written == 2);
}

fn utf8_topic_filter_statuses() {
    assert(honkmqtt::valid_utf8(""));
    assert(honkmqtt::valid_utf8("a"));
    assert(!honkmqtt::valid_utf8([0]));
    assert(!honkmqtt::valid_utf8([0xc2]));
    assert(honkmqtt::valid_topic("a"));
    assert(!honkmqtt::valid_topic(""));
    assert(!honkmqtt::valid_topic("+"));
    assert(!honkmqtt::valid_topic("#"));
    assert(honkmqtt::valid_filter("+"));
    assert(honkmqtt::valid_filter("#"));
    assert(honkmqtt::valid_filter("a/+/#"));
    assert(!honkmqtt::valid_filter(""));
    assert(!honkmqtt::valid_filter("a/#/b"));
    assert(!honkmqtt::valid_filter("a+"));
}

fn publish_statuses() {
    // OK QoS 0
    let packet: u8[7] = [0x30, 5, 0, 1, 'a', 9, 9];
    let s, u, t, l, p, id = honkmqtt::publish(packet, 5);
    assert(s == honkmqtt::OK && u == 7 && t == 4 && l == 1 && p == 5 && id == 0);
    // INCOMPLETE: empty and truncated; all other results zero
    let e, eu, et, el, ep, ei = honkmqtt::publish("", 10);
    assert(e == honkmqtt::INCOMPLETE && eu == 0 && et == 0 && el == 0 && ep == 0 && ei == 0);
    let tr, tu, tt, tl, tp, ti = honkmqtt::publish(packet[0..3], 5);
    assert(tr == honkmqtt::INCOMPLETE && tu == 0 && tt == 0 && tl == 0 && tp == 0 && ti == 0);
    // INVALID: non-PUBLISH, bad max_body, empty topic
    let np, npu, npt, npl, npp, npi = honkmqtt::publish([0xc0, 0], 10);
    assert(np == honkmqtt::INVALID && npu == 0 && npt == 0 && npl == 0 && npp == 0 && npi == 0);
    let nm, nmu, nmt, nml, nmp, nmi = honkmqtt::publish(packet, -2);
    assert(nm == honkmqtt::INVALID && nmu == 0 && nmt == 0 && nml == 0 && nmp == 0 && nmi == 0);
    let etopic: u8[4] = [0x30, 2, 0, 0];
    let et, eu2, et2, el2, ep2, ei2 = honkmqtt::publish(etopic, 2);
    assert(et == honkmqtt::INVALID && eu2 == 0 && et2 == 0 && el2 == 0 && ep2 == 0 && ei2 == 0);
}

fn matches_statuses() {
    assert(honkmqtt::matches("a/b", "a/b"));
    assert(honkmqtt::matches("+/b", "a/b"));
    assert(honkmqtt::matches("a/#", "a"));
    assert(!honkmqtt::matches("a/b", "a/c"));
    // Invalid filter or topic name => false (not a status code API).
    assert(!honkmqtt::matches("", "a"));
    assert(!honkmqtt::matches("a", ""));
    assert(!honkmqtt::matches("+", "$SYS"));
    assert(!honkmqtt::matches("#", "$SYS"));
    assert(!honkmqtt::matches("a+", "a+"));
}

fn main() {
    header_statuses();
    frame_statuses();
    encode_statuses();
    utf8_topic_filter_statuses();
    publish_statuses();
    matches_statuses();
    print("API behavioral matrix passed");
}
