# Transport integration

The codec accepts byte slices and returns status, lengths, and offsets.
Your transport decides when to read, write, or close a connection. It also
handles session state and timeouts.

## Size the buffers

Choose a body limit that your application can hold. A fixed header occupies
up to five bytes, so a receive window sized for `max_body + 5` can hold an
entire permitted frame. A separate transmit buffer bounds how many outbound
bytes you can queue. Plan for backpressure when either buffer fills.

## Receive one frame at a time

1. Append bytes to the receive window. Keep any bytes left by an earlier read.
2. Call `honkmqtt::frame(window, max_body)`. On `INCOMPLETE`, leave the window
   intact and wait for more bytes. On `INVALID`, apply the connection's error
   policy. The codec reports zero consumption in both cases.
3. On `OK`, take `window[0..consumed]`. Choose the typed parser using the high
   four bits of its first byte. Inspect packet fields only after that parser
   succeeds.
4. Finish using borrowed views, or copy the fields you need later. Advance
   the window by exactly `consumed` and repeat while complete frames remain.

At EOF, process complete buffered frames before classifying the connection.
An empty window means a clean end to the byte stream. A partial frame
indicates truncation.

## Handle partial writes

Encode into a caller-owned buffer that is disjoint from the input fields.
On `OK`, queue just the reported bytes. On `NO_SPACE`, retry with more
capacity. When the transport writes only part of the pending bytes, keep
the rest queued and retry when it signals readiness. Advance the cursor by
the actual write count.

See the [codec API](api.md#status-and-buffer-contracts) for error and
ownership rules.

## Use the bounded adapter example

The example package in `examples/stream` operates on caller-owned RX and TX
buffers. The entry program declares both `honkmqtt` and `stream` imports.
Run the deterministic short-I/O demo from a checkout.

```sh
goose run examples/transport.goose
```

Pending bytes occupy `buf[start..end]`. Use `stream::rx_capacity_for(max_body)`
to size RX. It returns `max_body + HEADER_MAX` for limits from 0 through
`MAX_BODY - HEADER_MAX`, or `-1` otherwise.

| Operation | How to use it |
| --- | --- |
| `feed` | Append up to `max_n` bytes. Use the returned `taken` count and keep any excess source bytes. A zero-byte request or empty source yields `WAIT`. A full window can yield `NO_SPACE`. |
| `commit_rx` | Advance only after processing a complete frame. Finish reading its borrowed fields first. |
| `enqueue` | Queue a whole packet, or return `NO_SPACE` with the packet still the caller's responsibility. |
| `drain` and `commit_tx` | Obtain the writable byte count, then advance by the number actually sent. An empty queue or zero-byte request yields `WAIT`. |
| `on_eof` | After draining complete frames, classify an empty window as `CLOSED` and a remaining partial frame as `TRUNCATED`. |

The commit operations advance the start cursor. `feed` compacts when the RX
tail is full and consumed bytes leave room. `enqueue` compacts when a packet
fits in total free space but exceeds the remaining tail. Keep the `feed`
source disjoint from the entire RX buffer and the packet passed to
`enqueue` disjoint from the entire TX buffer. Compaction can overwrite
consumed bytes. Finish using RX views before the next operation that changes
the window or reuses its storage.

The adapter is an example package with its own status constants and release
scope. [Adapter source](../examples/stream/stream.goose) ·
[Regression evidence](../examples/stream/REGRESSION.md)

## Try the broker examples

The TCP example gives Python ownership of sockets and gives Goose ownership
of framing, typed packet parsing, and buffer cursors. The bridge returns
the actual socket send count and honors a bounded receive request.

The recorded loopback runs use Mosquitto 2.0.18 and Aedes 0.51.3. Each
broker was tested for QoS 0, 1, and 2 publish delivery, unsubscribe,
closure on malformed input, and reconnection. The QoS 1 and 2 cases
verify identifiers and acknowledgements in both directions. The malformed
case accepts a confirmed EOF or reset, and a timeout fails that case.

See the setup, limits, and results in the
[TCP interoperability record](../examples/tcp/INTEROP.md). The
[broker benchmark](../baselines/m3-broker-loopback.md) records the
separate QoS 0 throughput, latency, and memory workloads.
