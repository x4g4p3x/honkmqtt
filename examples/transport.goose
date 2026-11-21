// Runnable M3 bounded transport-adapter demo (example-only helper).
// Deterministic short I/O over caller-owned buffers; HonkMQTT core unchanged.
import honkmqtt from "..";
import stream from "./stream";

const RX_CAP = 64;
const TX_CAP = 32;
const MAX_BODY = RX_CAP - stream::HEADER_MAX;

fn try_frame(rx: const u8[:], start: i64, end: i64) -> i64, i64 {
    return honkmqtt::frame(rx[start..end], MAX_BODY);
}

fn main() {
    assert(stream::rx_capacity_for(MAX_BODY) == RX_CAP);

    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_s = 0;
    var rx_e = 0;
    var tx_s = 0;
    var tx_e = 0;
    var frames = 0;
    var fatal = false;

    // Scripted peer bytes: PINGREQ, PINGRESP, DISCONNECT (independent wire).
    let peer: u8[6] = [0xc0, 0x00, 0xd0, 0x00, 0xe0, 0x00];
    var pos = 0;

    while pos < peer.len && !fatal {
        let st, ns, ne, taken = stream::feed(rx, rx_s, rx_e, peer[pos..peer.len], 1);
        if st == stream::WAIT { break; }
        if st != stream::OK {
            fatal = true;
            break;
        }
        rx_s = ns;
        rx_e = ne;
        pos += taken;

        loop {
            let fs, used = try_frame(rx, rx_s, rx_e);
            if fs == honkmqtt::INCOMPLETE { break; }
            if fs != honkmqtt::OK {
                fatal = true;
                break;
            }
            // Frame view rx[rx_s..rx_s+used) expires after enqueue/commit_rx.
            let es, ts, te = stream::enqueue(tx, tx_s, tx_e, rx[rx_s..rx_s + used]);
            if es != stream::OK {
                fatal = true;
                break;
            }
            tx_s = ts;
            tx_e = te;
            let cs, rs, re = stream::commit_rx(rx_s, rx_e, used);
            assert(cs == stream::OK);
            rx_s = rs;
            rx_e = re;
            frames += 1;
        }
    }
    assert(!fatal && pos == peer.len && frames == 3);
    assert(stream::pending(rx_s, rx_e) == 0);
    assert(stream::on_eof(stream::pending(rx_s, rx_e)) == stream::CLOSED);

    // Short writes: commit advances start only (no per-write TX shift).
    var out: u8[6] = [0; 6];
    var out_len = 0;
    while stream::pending(tx_s, tx_e) > 0 {
        let ds, n = stream::drain(tx_s, tx_e, 1);
        if ds == stream::WAIT { break; }
        assert(ds == stream::OK && n == 1);
        out[out_len] = tx[tx_s];
        out_len += 1;
        let cs, ns, ne = stream::commit_tx(tx_s, tx_e, n);
        assert(cs == stream::OK);
        tx_s = ns;
        tx_e = ne;
    }
    assert(out_len == 6 && stream::pending(tx_s, tx_e) == 0);
    for i in 6 { assert(out[i] == peer[i]); }

    print(
        "transport adapter: frames=", frames,
        " echoed=", out_len,
        " rx_cap=", RX_CAP,
        " max_body=", MAX_BODY,
        " ok",
    );
}
