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
    var ack: u8[4] = [0; 4];
    let aks, akn = honkmqtt::encode_pubresp(honkmqtt::PUBACK, 1, ack);
    assert(aks == honkmqtt::OK && akn == 4);
    let rs, ru, rid = honkmqtt::pubresp(ack, honkmqtt::PUBACK);
    assert(rs == honkmqtt::OK && ru == 4 && rid == 1);
    var ca: u8[4] = [0; 4];
    let cs, cn = honkmqtt::encode_connack(false, 0, ca);
    assert(cs == honkmqtt::OK && cn == 4);
    let ks, ku, sp, rc = honkmqtt::connack(ca);
    assert(ks == honkmqtt::OK && ku == 4 && sp == false && rc == 0);
    print("PINGREQ frame: ", size, " bytes; PUBLISH encoded: ", n, " bytes; PUBACK id=", rid, "; CONNACK rc=", rc);
}
