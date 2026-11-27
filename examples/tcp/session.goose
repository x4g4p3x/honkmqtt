// M3 TCP interop client: drives examples/stream over a length-prefixed pipe
// protocol. The Python bridge owns real TCP short I/O + send byte counts;
// Goose owns feed/frame/commit_rx and enqueue/drain/commit_tx + codecs.
// No print() — stdout is binary IPC only.
import os;
import honkmqtt from "../..";
import stream from "../stream";

const RX_CAP = 256;
const TX_CAP = 256;
const MAX_BODY = RX_CAP - stream::HEADER_MAX; // 251
const RECV_MAX = 64;   // short-read soft cap (also limited by free RX window)
const IPC_MAX = 512;   // hard cap on one IPC payload
const KEEP_ALIVE = 30;
const SUB_ID = 7;

// Goose -> bridge
const MSG_SEND = 1;
const MSG_RECV = 2;
const MSG_EVENT = 3;
const MSG_DONE = 4;
const MSG_FATAL = 5;
const MSG_RECONNECT = 6;

// Bridge -> Goose
const MSG_DATA = 10;
const MSG_ERR = 11;

fn fail(msg: const u8[:]) {
    emit(MSG_FATAL, msg);
    exit(1);
}

fn emit(kind: i64, payload: const u8[:]) {
    if payload.len > IPC_MAX { abort("ipc payload too large"); }
    var hdr: u8[3] = [0; 3];
    hdr[0] = kind as u8;
    hdr[1] = (payload.len / 256) as u8;
    hdr[2] = (payload.len % 256) as u8;
    write_stdout(hdr);
    if payload.len > 0 { write_stdout(payload); }
    flush_stdout();
}

fn emit_event(msg: const u8[:]) {
    emit(MSG_EVENT, msg);
}

fn read_exact(n: i64, out: u8[>..]&) -> bool {
    while out.len < n {
        let before = out.len;
        let ok = read_stdin(out, n - out.len);
        if !ok && out.len == before { return false; }
        if out.len == before { return false; }
    }
    return true;
}

fn recv_msg(payload: u8[>..]&) -> i64 {
    payload.clear();
    var hdr: u8[>..] = [];
    if !read_exact(3, hdr) { return -1; }
    let kind = hdr[0] as i64;
    let hi = hdr[1] as i64;
    let lo = hdr[2] as i64;
    let n = hi * 256 + lo;
    if n < 0 || n > IPC_MAX { return -1; }
    if n > 0 && !read_exact(n, payload) { return -1; }
    return kind;
}

// SEND → wait for DATA u16be sent count (actual socket.send) or ERR.
fn socket_send(bytes: const u8[:]) -> i64 {
    if bytes.len == 0 { return 0; }
    emit(MSG_SEND, bytes);
    var reply: u8[>..] = [];
    let kind = recv_msg(reply);
    if kind == MSG_ERR {
        fail(reply);
    }
    if kind != MSG_DATA || reply.len != 2 { fail("bad SEND ack"); }
    let hi = reply[0] as i64;
    let lo = reply[1] as i64;
    let sent = hi * 256 + lo;
    if sent <= 0 || sent > bytes.len { fail("SEND ack out of range"); }
    return sent;
}

fn socket_recv(max_n: i64, dst: u8[>..]&) -> i64 {
    // Returns: 0=DATA (possibly empty EOF), 1=ERR (dst holds reason UTF-8)
    dst.clear();
    if max_n <= 0 { return 0; }
    var req: u8[2] = [0; 2];
    req[0] = (max_n / 256) as u8;
    req[1] = (max_n % 256) as u8;
    emit(MSG_RECV, req);
    let kind = recv_msg(dst);
    if kind == MSG_DATA { return 0; }
    if kind == MSG_ERR { return 1; }
    fail("bad bridge reply to RECV");
    return 1;
}

fn flush_tx(tx: u8[:], tx_s: i64&, tx_e: i64&) {
    while stream::pending(tx_s, tx_e) > 0 {
        let ds, n = stream::drain(tx_s, tx_e, RECV_MAX);
        if ds == stream::WAIT { break; }
        if ds != stream::OK { fail("drain failed"); }
        // Bridge may short-write; commit only acknowledged bytes.
        let sent = socket_send(tx[tx_s..tx_s + n]);
        let cs, ns, ne = stream::commit_tx(tx_s, tx_e, sent);
        if cs != stream::OK { fail("commit_tx failed"); }
        tx_s = ns;
        tx_e = ne;
    }
}

fn enqueue_packet(tx: u8[:], tx_s: i64&, tx_e: i64&, packet: const u8[:]) {
    let st, ns, ne = stream::enqueue(tx, tx_s, tx_e, packet);
    if st != stream::OK { fail("enqueue failed"); }
    tx_s = ns;
    tx_e = ne;
    flush_tx(tx, tx_s, tx_e);
}

// feed() only compacts when end==len; never request more than free tail.
fn rx_tail_free(rx_len: i64, rx_e: i64) -> i64 {
    if rx_e < 0 || rx_e > rx_len { return 0; }
    return rx_len - rx_e;
}

fn feed_socket(
    rx:    u8[:],
    rx_s:  i64&,
    rx_e:  i64&,
    chunk: u8[>..]&,
) -> i64 {
    // 0=DATA after RECV (chunk empty ⇒ socket EOF), 1=ERR, 2=BACKPRESSURE (no RECV).
    chunk.clear();
    var tail = rx_tail_free(rx.len, rx_e);
    if tail == 0 {
        if rx_s == rx_e {
            // Empty window parked at end (commit_rx advanced start to len) —
            // reset so subsequent recv/feed can use the buffer again.
            rx_s = 0;
            rx_e = 0;
            tail = rx.len;
        } else if rx_s > 0 {
            // Reclaim headroom before the next short read.
            let cs, ns, ne = stream::compact(rx, rx_s, rx_e);
            if cs != stream::OK { fail("compact failed"); }
            rx_s = ns;
            rx_e = ne;
            tail = rx_tail_free(rx.len, rx_e);
        }
        if tail == 0 {
            return 2; // window full — caller must commit_rx or wait
        }
    }
    var want = RECV_MAX;
    if want > tail { want = tail; }
    let r = socket_recv(want, chunk);
    if r == 1 { return 1; }
    if chunk.len == 0 { return 0; } // real EOF from bridge after RECV
    if chunk.len > want { fail("bridge exceeded recv cap"); }
    // Staging disjoint from rx (stream non-overlap contract).
    var staging: u8[RECV_MAX] = [0; RECV_MAX];
    for i in chunk.len { staging[i] = chunk[i]; }
    let st, ns, ne, taken = stream::feed(rx, rx_s, rx_e, staging[0..chunk.len], chunk.len);
    if st == stream::WAIT { return 2; }
    if st != stream::OK { fail("feed failed"); }
    rx_s = ns;
    rx_e = ne;
    if taken != chunk.len { fail("short feed"); }
    return 0;
}

fn scenario_name() -> u8[>..] {
    let a = args();
    var out: u8[>..] = [];
    if a.len > 1 {
        for i in a[1].len { out.push(a[1][i]); }
    } else {
        for c in "positive" { out.push(c); }
    }
    return out;
}

fn client_id_arg() -> u8[>..] {
    let a = args();
    var out: u8[>..] = [];
    if a.len > 2 {
        for i in a[2].len { out.push(a[2][i]); }
    } else {
        for c in "honk-m3" { out.push(c); }
    }
    return out;
}

fn number_arg(index: i64, fallback: i64, maximum: i64) -> i64 {
    let a = args();
    if a.len <= index { return fallback; }
    if a[index].len == 0 { return fallback; }
    var value = 0;
    for i in a[index].len {
        let c = a[index][i] as i64;
        if c < 48 || c > 57 { return fallback; }
        let digit = c - 48;
        if value > (maximum - digit) / 10 { return -1; }
        value = value * 10 + digit;
    }
    return value;
}

fn eq_str(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len { if a[i] != b[i] { return false; } }
    return true;
}

fn eq_bytes(a: const u8[:], b: const u8[:]) -> bool {
    return eq_str(a, b);
}

fn tcp_reconnect() {
    emit(MSG_RECONNECT, "");
    var ack: u8[>..] = [];
    let kind = recv_msg(ack);
    if kind != MSG_DATA { fail("reconnect ack expected DATA"); }
}

fn do_connect(
    rx:        u8[:],
    rx_s:      i64&,
    rx_e:      i64&,
    tx:        u8[:],
    tx_s:      i64&,
    tx_e:      i64&,
    client_id: const u8[:],
    chunk:     u8[>..]&,
) {
    var pkt: u8[TX_CAP] = [0; TX_CAP];
    let es, en = honkmqtt::encode_connect(
        true, KEEP_ALIVE, client_id,
        false, 0, false, "", "",
        false, "", false, "",
        pkt,
    );
    if es != honkmqtt::OK { fail("encode_connect"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);

    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::OK {
            let cs, consumed, session, code = honkmqtt::connack(rx[rx_s..rx_s + used]);
            if cs != honkmqtt::OK || consumed != used { fail("connack parse"); }
            if code != 0 { fail("connack refused"); }
            let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
            rx_s = ns;
            rx_e = ne;
            if session {
                emit_event("CONNACK session=1 code=0");
            } else {
                emit_event("CONNACK session=0 code=0");
            }
            return;
        }
        if fs == honkmqtt::INVALID { fail("frame invalid during connack"); }
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 { fail(chunk); }
        if fr == 2 { continue; }
        if chunk.len == 0 { fail("EOF before CONNACK"); }
    }
}

fn do_subscribe(
    rx:    u8[:],
    rx_s:  i64&,
    rx_e:  i64&,
    tx:    u8[:],
    tx_s:  i64&,
    tx_e:  i64&,
    chunk: u8[>..]&,
) {
    let list: u8[7] = [0x00, 0x04, 0x6d, 0x33, 0x2f, 0x74, 0x00]; // m3/t qos0
    var pkt: u8[TX_CAP] = [0; TX_CAP];
    let es, en = honkmqtt::encode_subscribe(SUB_ID, list, pkt);
    if es != honkmqtt::OK { fail("encode_subscribe"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);

    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::OK {
            let ss, consumed, id, co, cl = honkmqtt::suback(rx[rx_s..rx_s + used], MAX_BODY);
            if ss != honkmqtt::OK || consumed != used { fail("suback parse"); }
            if id != SUB_ID { fail("suback id mismatch"); }
            if cl < 1 { fail("suback empty codes"); }
            let code = rx[rx_s + co] as i64;
            if code != 0 { fail("suback code"); }
            let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
            rx_s = ns;
            rx_e = ne;
            emit_event("SUBACK id=7 code=0");
            return;
        }
        if fs == honkmqtt::INVALID { fail("frame invalid during suback"); }
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 { fail(chunk); }
        if fr == 2 { continue; }
        if chunk.len == 0 { fail("EOF before SUBACK"); }
    }
}

fn expect_topic_payload(
    view:    const u8[:],
    topic_o: i64,
    topic_n: i64,
    pay_o:   i64,
    end:     i64,
) -> bool {
    let want_topic: u8[4] = [0x6d, 0x33, 0x2f, 0x74]; // m3/t
    let want_pay:   u8[3] = [0x68, 0x69, 0x21];       // hi!
    if topic_n != want_topic.len { return false; }
    if !eq_bytes(view[topic_o..topic_o + topic_n], want_topic) { return false; }
    let pay_n = end - pay_o;
    if pay_n != want_pay.len { return false; }
    return eq_bytes(view[pay_o..pay_o + pay_n], want_pay);
}

// Publish QoS0 then verify typed inbound PUBLISH (same-client delivery).
fn do_publish_exchange(
    rx:    u8[:],
    rx_s:  i64&,
    rx_e:  i64&,
    tx:    u8[:],
    tx_s:  i64&,
    tx_e:  i64&,
    chunk: u8[>..]&,
) {
    var pkt: u8[TX_CAP] = [0; TX_CAP];
    let topic:   u8[4] = [0x6d, 0x33, 0x2f, 0x74];
    let payload: u8[3] = [0x68, 0x69, 0x21];
    let es, en = honkmqtt::encode_publish(false, 0, false, topic, 0, payload, pkt);
    if es != honkmqtt::OK { fail("encode_publish"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);
    emit_event("PUBLISH qos0 sent");

    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::OK {
            let view = rx[rx_s..rx_s + used];
            let ps, consumed, to, tn, po, _ = honkmqtt::publish(view, MAX_BODY);
            if ps == honkmqtt::OK && consumed == used {
                if expect_topic_payload(view, to, tn, po, consumed) {
                    let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
                    rx_s = ns;
                    rx_e = ne;
                    emit_event("PUBLISH verified topic=m3/t payload=hi!");
                    return;
                }
                fail("PUBLISH topic/payload mismatch");
            }
            // Unexpected control while waiting for echo — reject PINGRESP etc.
            let pr, _ = honkmqtt::pingresp(view);
            if pr == honkmqtt::OK { fail("unexpected PINGRESP during publish wait"); }
            fail("unexpected frame during publish wait");
        }
        if fs == honkmqtt::INVALID { fail("frame invalid during publish wait"); }
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 { fail(chunk); }
        if fr == 2 { continue; }
        if chunk.len == 0 { fail("EOF before PUBLISH echo"); }
    }
}

fn bench_payload_byte(index: i64, sequence: i64) -> u8 {
    if index == 0 { return ((sequence / 16777216) % 256) as u8; }
    if index == 1 { return ((sequence / 65536) % 256) as u8; }
    if index == 2 { return ((sequence / 256) % 256) as u8; }
    if index == 3 { return (sequence % 256) as u8; }
    return ((index * 131 + 0x41 + sequence * 17) % 256) as u8;
}

fn expect_bench_payload(
    view:      const u8[:],
    topic_o:   i64,
    topic_n:   i64,
    pay_o:     i64,
    end:       i64,
    payload_n: i64,
    sequence:  i64,
) -> bool {
    let want_topic: u8[4] = [0x6d, 0x33, 0x2f, 0x74]; // m3/t
    if topic_n != want_topic.len { return false; }
    if !eq_bytes(view[topic_o..topic_o + topic_n], want_topic) { return false; }
    if end - pay_o != payload_n { return false; }
    for i in payload_n {
        if view[pay_o + i] != bench_payload_byte(i, sequence) { return false; }
    }
    return true;
}

fn do_bench_exchange(
    rx:       u8[:], rx_s: i64&, rx_e: i64&,
    tx:       u8[:], tx_s: i64&, tx_e: i64&,
    chunk:    u8[>..]&, payload_n: i64, sequence: i64, sample_index: i64,
    measured: bool, starts: i64[:], ends: i64[:],
) {
    let start_tick = clock_ns();
    var pkt: u8[TX_CAP] = [0; TX_CAP];
    let topic: u8[4] = [0x6d, 0x33, 0x2f, 0x74];
    var payload: u8[240] = [0; 240];
    if payload_n < 4 || payload_n > payload.len { fail("payload size out of range"); }
    for i in payload_n { payload[i] = bench_payload_byte(i, sequence); }
    let es, en = honkmqtt::encode_publish(false, 0, false, topic, 0, payload[0..payload_n], pkt);
    if es != honkmqtt::OK { fail("encode_publish"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);
    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::OK {
            let view = rx[rx_s..rx_s + used];
            let ps, consumed, to, tn, po, _ = honkmqtt::publish(view, MAX_BODY);
            if ps != honkmqtt::OK || consumed != used { fail("benchmark echo PUBLISH parse"); }
            if !expect_bench_payload(view, to, tn, po, consumed, payload_n, sequence) {
                fail("benchmark echo payload mismatch");
            }
            let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
            rx_s = ns;
            rx_e = ne;
            if measured {
                let end_tick = clock_ns();
                starts[sample_index] = start_tick;
                ends[sample_index] = end_tick;
            }
            return;
        }
        if fs == honkmqtt::INVALID { fail("invalid benchmark echo frame"); }
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 { fail(chunk); }
        if fr == 2 { continue; }
        if chunk.len == 0 { fail("EOF before benchmark echo"); }
    }
}

fn do_ping(
    rx:    u8[:],
    rx_s:  i64&,
    rx_e:  i64&,
    tx:    u8[:],
    tx_s:  i64&,
    tx_e:  i64&,
    chunk: u8[>..]&,
) {
    var pkt: u8[2] = [0; 2];
    let es, en = honkmqtt::encode_pingreq(pkt);
    if es != honkmqtt::OK { fail("encode_pingreq"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);

    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::OK {
            let view = rx[rx_s..rx_s + used];
            let ps, consumed = honkmqtt::pingresp(view);
            if ps == honkmqtt::OK && consumed == used {
                let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
                rx_s = ns;
                rx_e = ne;
                emit_event("PINGRESP ok");
                return;
            }
            // Late PUBLISH after ping — accept only if verified, then keep waiting.
            let pub_st, pub_used, to, tn, po, _ = honkmqtt::publish(view, MAX_BODY);
            if pub_st == honkmqtt::OK && pub_used == used {
                if expect_topic_payload(view, to, tn, po, pub_used) {
                    let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
                    rx_s = ns;
                    rx_e = ne;
                    emit_event("PUBLISH verified topic=m3/t payload=hi!");
                    continue;
                }
            }
            fail("pingresp parse");
        }
        if fs == honkmqtt::INVALID { fail("frame invalid during pingresp"); }
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 { fail(chunk); }
        if fr == 2 { continue; }
        if chunk.len == 0 { fail("EOF before PINGRESP"); }
    }
}

fn do_disconnect(tx: u8[:], tx_s: i64&, tx_e: i64&) {
    var pkt: u8[2] = [0; 2];
    let es, en = honkmqtt::encode_disconnect(pkt);
    if es != honkmqtt::OK { fail("encode_disconnect"); }
    enqueue_packet(tx, tx_s, tx_e, pkt[0..en]);
    emit_event("DISCONNECT sent");
}

fn reason_is_eof_or_reset(reason: const u8[:]) -> bool {
    if eq_str(reason, "EOF") { return true; }
    if eq_str(reason, "RESET") { return true; }
    return false;
}

// Discard every complete buffered frame; fail on PINGRESP. Returns true if the
// window still holds an incomplete prefix (or INVALID retained).
fn drain_complete_frames(rx: u8[:], rx_s: i64&, rx_e: i64&) -> bool {
    loop {
        let fs, used = honkmqtt::frame(rx[rx_s..rx_e], MAX_BODY);
        if fs == honkmqtt::INCOMPLETE { return stream::pending(rx_s, rx_e) > 0; }
        if fs == honkmqtt::INVALID {
            emit_event("RX_INVALID retained");
            return true;
        }
        if fs != honkmqtt::OK { fail("frame status awaiting close"); }
        let view = rx[rx_s..rx_s + used];
        let pr, _ = honkmqtt::pingresp(view);
        if pr == honkmqtt::OK { fail("unexpected PINGRESP after malformed"); }
        let _, ns, ne = stream::commit_rx(rx_s, rx_e, used);
        rx_s = ns;
        rx_e = ne;
        emit_event("RX frame discarded awaiting close");
    }
}

// Wait until peer closes. Accept only bridge-observed EOF/RESET (after RECV).
// Drain all complete buffered frames before each read and before finalizing.
fn wait_peer_close(rx: u8[:], rx_s: i64&, rx_e: i64&, chunk: u8[>..]&) {
    loop {
        let held = drain_complete_frames(rx, rx_s, rx_e);
        let fr = feed_socket(rx, rx_s, rx_e, chunk);
        if fr == 1 {
            if !reason_is_eof_or_reset(chunk) { fail(chunk); }
            let _ = drain_complete_frames(rx, rx_s, rx_e);
            var line: u8[>..] = [];
            for c in "PEER_CLOSE reason=" { line.push(c); }
            for i in chunk.len { line.push(chunk[i]); }
            emit_event(line);
            return;
        }
        if fr == 0 && chunk.len == 0 {
            let _ = drain_complete_frames(rx, rx_s, rx_e);
            emit_event("PEER_CLOSE reason=EOF");
            return;
        }
        if fr == 2 {
            if held { fail("RX backpressure with incomplete/INVALID awaiting close"); }
            // Empty window should have been reset inside feed_socket; retry.
            continue;
        }
        // Bytes fed — loop to drain any newly completed frames first.
    }
}

fn reset_cursors(rx_s: i64&, rx_e: i64&, tx_s: i64&, tx_e: i64&) {
    rx_s = 0;
    rx_e = 0;
    tx_s = 0;
    tx_e = 0;
}

fn run_positive(client_id: const u8[:]) {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_s = 0;
    var rx_e = 0;
    var tx_s = 0;
    var tx_e = 0;
    var chunk: u8[>..] = [];

    emit_event("BOUNDS rx=256 tx=256 max_body=251 recv_max=64 ipc_max=512");
    emit_event("BRIDGE_MODEL send_ack=socket.send_count recv_cap=min(64,rx_tail_free)");
    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    do_subscribe(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_publish_exchange(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_ping(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_disconnect(tx, tx_s, tx_e);
    emit(MSG_DONE, [0]);
}

fn run_benchmark(client_id: const u8[:], payload_n: i64, warmup_n: i64, measured_n: i64) {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_s = 0;
    var rx_e = 0;
    var tx_s = 0;
    var tx_e = 0;
    var chunk:  u8[>..]   = [];
    var starts: i64[1000] = [0; 1000];
    var ends:   i64[1000] = [0; 1000];
    if payload_n < 4 || payload_n > 240 || warmup_n < 0 || warmup_n > 50
        || measured_n < 1 || measured_n > starts.len {
        fail("bad benchmark arguments");
    }
    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    do_subscribe(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    for i in warmup_n {
        do_bench_exchange(
            rx, rx_s, rx_e, tx, tx_s, tx_e, chunk, payload_n, i, 0, false, starts, ends,
        );
    }
    emit_event("BENCH_MEASURE_BEGIN");
    for i in measured_n {
        do_bench_exchange(
            rx, rx_s, rx_e, tx, tx_s, tx_e, chunk, payload_n, warmup_n + i, i,
            true, starts, ends,
        );
    }
    emit_event("BENCH_MEASURE_END");
    for i in measured_n {
        var sample: u8[>..] = [];
        for c in "BENCH_SAMPLE " { sample.push(c); }
        format(sample, i);
        sample.push(' ');
        format(sample, starts[i]);
        sample.push(' ');
        format(sample, ends[i]);
        emit_event(sample);
    }
    do_disconnect(tx, tx_s, tx_e);
    emit(MSG_DONE, [0]);
}

fn run_malformed(client_id: const u8[:]) {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_s = 0;
    var rx_e = 0;
    var tx_s = 0;
    var tx_e = 0;
    var chunk: u8[>..] = [];

    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    // Reserved type 0 — enqueue so SEND uses stream drain + send-ack commit.
    let bad: u8[2] = [0x00, 0x00];
    enqueue_packet(tx, tx_s, tx_e, bad);
    emit_event("MALFORMED sent type=0");
    wait_peer_close(rx, rx_s, rx_e, chunk);

    // Same client id reconnect after confirmed closure.
    tcp_reconnect();
    reset_cursors(rx_s, rx_e, tx_s, tx_e);
    emit_event("RECONNECTED after malformed");
    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    do_ping(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_disconnect(tx, tx_s, tx_e);
    emit(MSG_DONE, [0]);
}

fn run_reconnect(client_id: const u8[:]) {
    var rx: u8[RX_CAP] = [0; RX_CAP];
    var tx: u8[TX_CAP] = [0; TX_CAP];
    var rx_s = 0;
    var rx_e = 0;
    var tx_s = 0;
    var tx_e = 0;
    var chunk: u8[>..] = [];

    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    do_ping(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_disconnect(tx, tx_s, tx_e);

    tcp_reconnect();
    reset_cursors(rx_s, rx_e, tx_s, tx_e);
    emit_event("RECONNECTED");
    do_connect(rx, rx_s, rx_e, tx, tx_s, tx_e, client_id, chunk);
    do_ping(rx, rx_s, rx_e, tx, tx_s, tx_e, chunk);
    do_disconnect(tx, tx_s, tx_e);
    emit(MSG_DONE, [0]);
}

fn main() {
    if stream::rx_capacity_for(MAX_BODY) != RX_CAP { fail("rx capacity"); }
    let scen = scenario_name();
    let cid = client_id_arg();
    if eq_str(scen, "positive") {
        run_positive(cid);
    } else if eq_str(scen, "benchmark") {
        run_benchmark(
            cid,
            number_arg(3, 16, 240),
            number_arg(4, 10, 50),
            number_arg(5, 50, 1000),
        );
    } else if eq_str(scen, "malformed") {
        run_malformed(cid);
    } else if eq_str(scen, "reconnect") {
        run_reconnect(cid);
    } else {
        fail("unknown scenario");
    }
}
