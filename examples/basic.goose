import honkmqtt from "..";

fn main() {
    let status, size = honkmqtt::frame([0xc0, 0x00], 1024);
    assert(status == honkmqtt::OK && size == 2);
    assert(honkmqtt::matches("sensors/+/temp", "sensors/kitchen/temp"));
    print("PINGREQ frame: ", size, " bytes");
}
