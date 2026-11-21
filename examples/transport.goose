// Runnable M3 bounded transport-adapter demo.
// Uses the reusable `stream` byte-stream package with deterministic short I/O
// and HonkMQTT framing on caller-owned buffers (core unchanged).
import honkmqtt from "..";
import stream from "../stream";

const RX_CAP = 64;
const TX_CAP = 32;
const MAX_BODY = RX_CAP - stream::HEADER_MAX;

fn try_frame(rx: const u8[:], rx_len: i64) -> i64, i64 {
    return honkmqtt::frame(rx[0..rx_len], MAX_BODY);
}

fn main() {
    assert(stream::rx_capacity_for(MAX_BODY) == RX_CAP);

    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_len = 0;
    var tx_len = 0;
    var frames = 0;

    // Scripted peer bytes: PINGREQ, PINGRESP, DISCONNECT (independent wire).
    let peer: u8[6] = [0xc0, 0x00, 0xd0, 0x00, 0xe0, 0x00];
    var pos = 0;

    // Feed at most one byte per turn (short reads); never spin on WAIT.
    while pos < peer.len {
        let st, nl, taken = stream::feed(rx, rx_len, peer[pos..peer.len], 1);
        if st == stream::WAIT {
            // Zero progress: retain RX and stop this turn (no busy loop).
            break;
        }
        assert(st == stream::OK && taken == 1);
        rx_len = nl;
        pos += taken;

        loop {
            let fs, used = try_frame(rx, rx_len);
            if fs == honkmqtt::INCOMPLETE { break; }
            assert(fs == honkmqtt::OK && used >= 2);
            // Echo the exact frame bytes onto TX (may backpressure).
            let es, ntx = stream::enqueue(tx, tx_len, rx[0..used]);
            assert(es == stream::OK);
            tx_len = ntx;
            let _, nrx = stream::shift_rx(rx, rx_len, used);
            rx_len = nrx;
            frames += 1;
        }
    }
    assert(pos == peer.len && frames == 3 && rx_len == 0);
    assert(stream::on_eof(rx_len) == stream::CLOSED);

    // Drain TX with short writes of one byte; retain remainder each turn.
    var out: u8[6] = [0; 6];
    var out_len = 0;
    while tx_len > 0 {
        let ds, n = stream::drain(tx_len, 1);
        if ds == stream::WAIT { break; }
        assert(ds == stream::OK && n == 1);
        out[out_len] = tx[0];
        out_len += 1;
        let _, ntx = stream::shift_tx(tx, tx_len, n);
        tx_len = ntx;
    }
    assert(out_len == 6 && tx_len == 0);
    for i in 6 { assert(out[i] == peer[i]); }

    print(
        "transport adapter: frames=", frames,
        " echoed=", out_len,
        " rx_cap=", RX_CAP,
        " max_body=", MAX_BODY,
        " ok",
    );
}
