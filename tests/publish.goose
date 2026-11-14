import honkmqtt from "..";

fn rejected(input: const u8[:], limit: i64, expected: i64) {
    let status, used, topic, len, payload, id = honkmqtt::publish(input, limit);
    assert(status == expected && used == 0 && topic == 0 && len == 0 && payload == 0 && id == 0);
}

fn main() {
    // QoS 0, nonempty binary payload and a second frame following it.
    let packet: u8[12] = [0x30, 0x08, 0, 3, 'a', '/', 'b', 0, 0xff, 7, 0xc0, 0];
    let status, used, topic, len, payload, id = honkmqtt::publish(packet, 8);
    assert(status == honkmqtt::OK && used == 10 && topic == 4 && len == 3 && payload == 7 && id == 0);
    assert(packet[topic..topic + len] == "a/b" && packet[payload] == 0 && packet[payload + 1] == 0xff && packet[payload + 2] == 7);
    for n in 10 { rejected(packet[0..n], 8, honkmqtt::INCOMPLETE); }
    rejected(packet, 7, honkmqtt::INVALID);
    rejected(packet, -1, honkmqtt::INVALID);

    // QoS 1 and 2 have a nonzero big-endian identifier; empty payload is valid.
    let qos1: u8[7] = [0x32, 5, 0, 1, 'x', 0x12, 0x34];
    let s1, u1, t1, l1, p1, i1 = honkmqtt::publish(qos1, 5);
    assert(s1 == honkmqtt::OK && u1 == 7 && t1 == 4 && l1 == 1 && p1 == 7 && i1 == 0x1234);
    let qos2: u8[7] = [0x3c, 5, 0, 1, 'x', 0xff, 0xff];
    let s2, u2, _, _, p2, i2 = honkmqtt::publish(qos2, 5);
    assert(s2 == honkmqtt::OK && u2 == 7 && p2 == 7 && i2 == 65535);
    rejected([0x32, 5, 0, 1, 'x', 0, 0], 5, honkmqtt::INVALID);
    rejected([0x32, 4, 0, 1, 'x', 1], 4, honkmqtt::INVALID);
    // Bytes from the next frame must not complete a malformed current frame.
    rejected([0x32, 4, 0, 1, 'x', 1, 0xc0, 0], 4, honkmqtt::INVALID);

    // Two-byte Remaining Length, exactly at the 128-byte boundary.
    var large: u8[131] = [0; 131];
    large[0] = 0x30; large[1] = 0x80; large[2] = 1;
    large[3] = 0; large[4] = 1; large[5] = 'x';
    let ls, lu, lt, ll, lp, li = honkmqtt::publish(large, 128);
    assert(ls == honkmqtt::OK && lu == 131 && lt == 5 && ll == 1 && lp == 6 && li == 0);
    for n in 131 { rejected(large[0..n], 128, honkmqtt::INCOMPLETE); }
    rejected(large, 127, honkmqtt::INVALID);
    rejected([0x30, 0xff, 0xff, 0xff, 0x7f], 268435455, honkmqtt::INCOMPLETE);
    var max_topic: u8[65541] = [0x61; 65541];
    max_topic[0] = 0x30; max_topic[1] = 0x81; max_topic[2] = 0x80; max_topic[3] = 4;
    max_topic[4] = 0xff; max_topic[5] = 0xff;
    let ms, mu, mt, ml, mp, mi = honkmqtt::publish(max_topic, 65537);
    assert(ms == honkmqtt::OK && mu == 65541 && mt == 6 && ml == 65535 && mp == 65541 && mi == 0);

    rejected([0xc0, 0], 10, honkmqtt::INVALID);
    rejected([0x36, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 1, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 2, 0, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 3, 0, 2, 'x'], 10, honkmqtt::INVALID);
    rejected([0x30, 3, 0, 2, 'x', 0xc0, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 3, 0, 1, '+'], 10, honkmqtt::INVALID);
    rejected([0x30, 3, 0, 1, 0], 10, honkmqtt::INVALID);
    rejected([0x30, 3, 0, 1, 0xff], 10, honkmqtt::INVALID);
    let unicode: u8[7] = [0x30, 5, 0, 3, 0xe2, 0x82, 0xac];
    let us, uu, ut, ul, up, ui = honkmqtt::publish(unicode, 5);
    assert(us == honkmqtt::OK && uu == 7 && ut == 4 && ul == 3 && up == 7 && ui == 0);
    rejected([0x30, 0x80, 0], 10, honkmqtt::INVALID);
    print("PUBLISH tests passed");
}
