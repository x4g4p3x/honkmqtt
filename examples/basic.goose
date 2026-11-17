import honkmqtt from "..";

fn main() {
    let status, size = honkmqtt::frame([0xc0, 0x00], 1024);
    assert(status == honkmqtt::OK && size == 2);
    assert(honkmqtt::matches("sensors/+/temp", "sensors/kitchen/temp"));
    var pub_out: u8[32] = [0; 32];
    let es, n = honkmqtt::encode_publish(false, 0, false, "sensors/kitchen/temp", 0, "22", pub_out);
    assert(es == honkmqtt::OK && n > 0);
    let ps, used, _, _, _, _ = honkmqtt::publish(pub_out[0..n], 64);
    assert(ps == honkmqtt::OK && used == n);
    print("PINGREQ frame: ", size, " bytes; PUBLISH encoded: ", n, " bytes");
}
