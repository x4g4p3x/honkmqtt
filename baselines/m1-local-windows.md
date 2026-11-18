# M1 local optimized-build `encode_publish` baseline (Windows x64)

Single-machine snapshot for the M1 `publish_encode` workload. Not a CI SLA,
product throughput claim, or cross-platform ranking. Companion Linux (WSL2)
capture: `baselines/m1-local-linux.md`. Codec behavior is unchanged by this
measurement.

## Source and commands

| Pin | Value |
| --- | --- |
| Branch | `ao/m1-roadmap/encode-publish-baselines` |
| Base main | `4203d37add9473b44af35ac0a040e46973000349` |
| Command | `python scripts/bench.py --warmup 1 --samples 7` |
| Workload of record | `publish_encode` (`tests/bench_encode_publish.goose`) |

**SHA-256 of LF file bytes** (working-tree content with CRLF normalized to LF)
at capture:

| Path | SHA-256 | Size |
| --- | --- | --- |
| `honkmqtt.goose` | `67dc6135d1345206d30f4e94f3bf1bda8c7837a615dd7767da8d2cb190af2aeb` | 9611 |
| `tests/bench_encode_publish.goose` | `ce4ee2b39dc882eb54a9d4b4f8585c0e0adc11b72a218b7dd465e963ca17e8ee` | 5701 |
| `scripts/bench.py` | `89d2ecd85462f7a7e23481af5d0a7d628751385d94887cc8cad6229ee7a9a265` | 7325 |

Manifest SHA-256 (three `hash  path` lines, LF-separated):
`d0e1fb8e2634a9ba2554809672265ef27e649c6d12adcc3bcd61edbd82ac022c`

Reproduce:

```sh
python scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 tests/bench_encode_publish.goose` (scripted)
- Timing boundary: `steady_seconds` from Goose `clock()` around the timed loop
  only; process startup and one warmup run are excluded from recorded samples
- Included in timed loop: template copy into preallocated topic/payload buffers,
  runtime mutation, `encode_publish`, checksum fold over encoded length/bytes
- Excluded: argv parse, independent `expected_total` pre-pass, post-loop
  `clock_res_ns` probe, process startup
- Correctness: each sample must print checksum `17860248136` (independent of
  `encode_publish` before timing; runner fails on mismatch)
- Samples: serialized; warmup discarded; seven recorded samples

## Anti-elision

- **Runtime-dependent bytes:** each iteration copies a case template then writes
  loop-index-derived payload last-byte or packet-id-low values (`mutate_runtime`)
- **Independent expected outputs:** `expected_total` uses the same geometry and
  mutations without calling `encode_publish`; the timed loop aborts if encoded
  length/first byte disagree
- **Final optimized assembly (clang `-O2` of Goose `-O2` C):** timed loop
  (between `gs_os_clock_ns` calls) stores topic/payload bytes (e.g. `movb` /
  `movaps`), mutates a live byte (`movb %sil, …(%rbp,%rcx)`), then
  `callq honkmqtt_encode_publish_g8`; the callee retains validation and write
  path (not a no-op stub)

## Machine and toolchain

| Field | Value |
| --- | --- |
| Host | `MartinPC` |
| OS | Windows 11 Pro 10.0.26300 (64-bit) |
| CPU | AMD Ryzen 5 8600G (6 cores / 12 threads) |
| RAM | ~31.2 GiB |
| Goose | v2026.4 (runtime `dce889723a23`) |
| C compiler | clang 14.0.6 (`goose toolchain` id `clang-14.0.6-1591fbf5`) |
| Python | 3.14.0 |
| Clock resolution probe | `clock_res_ns=100` on every sample |

## Workload: `publish_encode`

- Source: `tests/bench_encode_publish.goose`
- Cases (4): QoS 0 short binary payload; QoS 1 empty + id mutation; QoS 2+DUP
  empty + id mutation; QoS 0+RETAIN with 64-byte payload
- Iterations: 1_000_000
- Expected checksum: `17860248136`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.012584600 | 100 |
| 2 | 0.013225100 | 100 |
| 3 | 0.012692100 | 100 |
| 4 | 0.012916900 | 100 |
| 5 | 0.013370600 | 100 |
| 6 | 0.013100700 | 100 |
| 7 | 0.012766000 | 100 |

Summary: n=7 min=0.012584600 median=0.012916900 max=0.013370600 mean=0.012950857

Raw sample variation (max − min): 0.000786000 s (~6.1% of mean)

## Limitations

- Single host; short representative packets; no network I/O
- Steady-state loop only; not an application throughput model
- No comparative speed claims versus other platforms or prior milestones
- M0 workloads also ran in the same `bench.py` invocation for runner continuity;
  this file records the M1 `publish_encode` series only
