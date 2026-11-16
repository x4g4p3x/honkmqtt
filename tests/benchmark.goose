// Combined encode + frame + topic-match workload. Times the steady-state loop
// only (excludes process startup). Run a native optimized build; verify the
// checksum; compare repeated samples externally.
import honkmqtt from "..";
import os;

fn main() {
    let argv = args();
    if argv.len != 5 { abort("expected body, filter, matching topic, non-matching topic"); }
    var total = 0;
    var buffer: u8[64] = [0; 64];
    let t0 = clock();
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
    let elapsed = clock() - t0;
    print("workload=encode_frame_match");
    print("iterations=", 1000000);
    print("checksum=", total);
    print("steady_seconds=", elapsed);
}
