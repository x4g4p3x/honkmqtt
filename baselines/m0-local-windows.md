# M0 local optimized-build baselines (Windows x64)

Recorded local baseline for HonkMQTT M0. This is a single-machine snapshot,
not a CI SLA, product throughput claim, or cross-platform ranking.

## Source and commands

- Base commit at measurement: `9d84fef8b30b65b333d13ec08a699de54d90e924` (`main`)
- Workloads introduced alongside this note: `tests/benchmark.goose`,
  `tests/bench_publish.goose`, runner `scripts/bench.py`
- Reproduce:

```sh
python scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 <workload.goose>` (scripted)
- Timing boundary: `steady_seconds` from Goose `clock()` around the timed loop
  only; process startup and one warmup run are excluded from recorded samples
- Correctness: each sample must print the expected checksum; the runner fails
  otherwise
- Samples: serialized; warmup discarded; seven recorded samples per workload

## Machine and toolchain

| Field | Value |
| --- | --- |
| Host | `MartinPC` |
| OS | Windows 11 Pro 10.0.26300 (64-bit) |
| CPU | AMD Ryzen 5 8600G (6 cores / 12 threads) |
| System | ASUS System Product Name |
| RAM | 33444020224 bytes (~31.2 GiB) |
| Goose | v2026.4 (runtime `dce889723a23`) |
| C compiler | clang 14.0.6 (`goose toolchain` id `clang-14.0.6-1591fbf5`) |
| Python | 3.14.0 |

## Workload: `encode_frame_match`

- Source: `tests/benchmark.goose`
- Inputs: body `sensor reading`; filter `sensors/+/temperature`; match
  `sensors/kitchen/temperature`; non-match `sensors/kitchen/humidity`
- Iterations: 1_000_000 encode+frame pairs with alternating matches
- Expected checksum: `16500000`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds |
| --- | --- |
| 1 | 0.059017100 |
| 2 | 0.058268100 |
| 3 | 0.058450400 |
| 4 | 0.055358200 |
| 5 | 0.053957200 |
| 6 | 0.055192400 |
| 7 | 0.057234000 |

Summary: n=7 min=0.053957200 median=0.057234000 max=0.059017100 mean=0.056782486

## Workload: `publish_parse`

- Source: `tests/bench_publish.goose`
- Input: fixed QoS 1 PUBLISH bytes `[0x32, 5, 0, 1, 'x', 0x12, 0x34]` (`max_body=5`)
- Iterations: 1_000_000
- Expected checksum: `4679000000` (= iterations × `(7+4+1+7+0x1234)`)

Raw `steady_seconds` after warmup:

| Sample | steady_seconds |
| --- | --- |
| 1 | 0.005981800 |
| 2 | 0.006215800 |
| 3 | 0.006099600 |
| 4 | 0.005977700 |
| 5 | 0.005953700 |
| 6 | 0.006461000 |
| 7 | 0.006077300 |

Summary: n=7 min=0.005953700 median=0.006077300 max=0.006461000 mean=0.006109557

## Limitations

- Local Windows x64 only; Linux CI hosts were not measured in this capture
- No network I/O, TLS, broker, or multi-connection workload
- Short fixed inputs only; not a general PUBLISH size sweep
- Results vary with background load, power policy, and toolchain upgrades
- Do not treat these numbers as release criteria or universal speed claims
