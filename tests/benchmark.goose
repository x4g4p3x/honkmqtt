// A small end-to-end framing and topic-matching workload. Run a native release
// build repeatedly; process startup is included in external wall-clock timing.
import honkmqtt from "..";
import os;

fn main() {
    let argv = args();
    if argv.len != 5 { abort("expected body, filter, matching topic, non-matching topic"); }
    var total = 0;
    var buffer: u8[64] = [0; 64];
    for i in 1000000 {
        let status, written = honkmqtt::encode(0x30, argv[1], buffer);
        let framed, used = honkmqtt::frame(buffer[0..written], 64);
        if status == honkmqtt::OK && framed == honkmqtt::OK { total += used; }
        if i % 2 == 0 {
            if honkmqtt::matches(argv[2], argv[3]) { total += 1; }
        } else {
            if honkmqtt::matches(argv[2], argv[4]) { total += 1; }
        }
    }
    print("checksum: ", total);
}
