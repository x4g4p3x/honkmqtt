# M0 local optimized-build baselines (Windows x64)

Recorded local baseline for HonkMQTT M0. This is a single-machine snapshot,
not a CI SLA, product throughput claim, or cross-platform ranking. M0 is not
marked complete from this capture alone (Linux host baselines remain a gap).

## Source and commands

Timed samples were captured while anti-elision workload changes were still
uncommitted atop `39fbd8f4a65a66fda06125e7accc864484c5a256`. Identity of the
measured library and benchmark sources is pinned by **SHA-256 of those file
bytes** (unchanged through the commit that freezes them on this branch).

| Pin | Value |
| --- | --- |
| Branch | `ao/m0-roadmap/m0-perf-baselines` |
| Pre-hardening baseline commit | `39fbd8f4a65a66fda06125e7accc864484c5a256` |
| Measurement identity | content hashes below (not the pre-hardening commit alone) |

**SHA-256 of measured library and benchmark sources** (file bytes that built and
timed the samples below; re-hash working tree or `git show <freeze>:path`):

| Path | SHA-256 | Size |
| --- | --- | --- |
| `honkmqtt.goose` | `fd26625e9203d50090387fce1ce3f2d20a82a016c18934aadeb3dea3a89708f6` | 7033 |
| `tests/bench_publish.goose` | `a3f40d46526ad5f23c6d276c5f989ee205eab02712c71b74ab1c1255a57c59ee` | 5141 |
| `tests/benchmark.goose` | `9ff1ec9d0d4fdd0a53311185291e46c4e345488fea11eb6bc8d0803bdf0c2bcd` | 4218 |
| `scripts/bench.py` | `8d837120677a600941206482639a16adc0c4f821fcf5e830993b5cdba5e3cc4c` | 7231 |

Manifest SHA-256 (of the four `hash  path` lines above, LF-separated, paths as
in the table):
`6c95ec565b0cd5922e77138c5f5aa06494e3eee5e478aab40a906df2ef006028`

Freeze commit for these bytes: see git history on this branch for the commit
that introduces the hardened workloads and this hash table (`git log -1 --
baselines/m0-local-windows.md` after that lands).

The raw sample tables below are from the official capture
(`python scripts/bench.py --warmup 1 --samples 7`) against those hashed
sources. A later confirmation rerun may show different wall times; checksums
must still match.

Reproduce (must match the hashes above for a like-for-like rerun):

```sh
python scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 <workload.goose>` (scripted)
- Timing boundary: `steady_seconds` from Goose `clock()` around the timed loop
  only; process startup and one warmup run are excluded from recorded samples
- Correctness: each sample must print the expected checksum; the runner fails
  otherwise. Expected totals are also asserted inside each workload against an
  independent precomputed table
- Samples: serialized; warmup discarded; seven recorded samples per workload
- Narrative files (`README.md`, `ROADMAP.md`, this note) may change after the
  timed run without invalidating the sample table, provided the four hashed
  sources above remain unchanged

## Anti-elision

Constant single-packet benches can be folded away by an optimizing compiler.
These workloads defend against that:

- **Runtime-varying inputs:** each iteration selects a case by loop index,
  copies bytes into a mutable buffer, then parses/encodes that buffer
- **Independent expected outputs:** fields (or match polarity) are checked
  against tables computed outside the timed checksum fold; wrong results abort
- **Live checksum:** timed path accumulates parsed/encoded values plus a
  runtime buffer byte so results cannot be discarded
- **Generated code inspection:** `goose -O2 -o …c` retains
  `honkmqtt_publish_g8` calls for both the probe and timed loops; clang `-O2`
  assembly of that C still contains `callq honkmqtt_publish_g8` in the timed
  loop. Combined workload C retains `honkmqtt_encode_g8` /
  `honkmqtt_frame_g8` / `honkmqtt_matches_g8` uses in the timed loop (encode
  and frame are `GS_INLINE` at the Goose C level)

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
| Clock resolution probe | `clock_res_ns=100` on every sample (min positive `clock_ns()` delta over 10000 paired reads) |

## Workload: `encode_frame_match`

- Source: `tests/benchmark.goose`
- Cases (3), copied into mutable buffers each iteration: bodies
  `sensor reading` / `temp` / `humidity-sample`; filters
  `sensors/+/temperature` / `sensors/#` / `sensors/+/humidity`; matching and
  non-matching topics per case
- Iterations: 1_000_000 encode+frame pairs with alternating match/miss checks
- Expected checksum: `118833334`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.047529500 | 100 |
| 2 | 0.047468000 | 100 |
| 3 | 0.049069900 | 100 |
| 4 | 0.047465300 | 100 |
| 5 | 0.046175900 | 100 |
| 6 | 0.047141700 | 100 |
| 7 | 0.048391800 | 100 |

Summary: n=7 min=0.046175900 median=0.047468000 max=0.049069900 mean=0.047606014

Raw sample variation (max − min): 0.002894000 s (~6.1% of mean)

## Workload: `publish_parse`

- Source: `tests/bench_publish.goose`
- Cases (4), copied each iteration: QoS0 `a/b` + 3-byte payload; QoS1 topic
  `x` id `0x1234`; QoS2+RETAIN+DUP topic `x` id `0xffff`; QoS0 topic `yz`
- Iterations: 1_000_000
- Expected checksum: `17700500000` (field sum per case + `buf[payload-1]` term,
  validated against an independent expectation table)

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.008658000 | 100 |
| 2 | 0.009013400 | 100 |
| 3 | 0.009085600 | 100 |
| 4 | 0.008634300 | 100 |
| 5 | 0.009174400 | 100 |
| 6 | 0.008642400 | 100 |
| 7 | 0.008703400 | 100 |

Summary: n=7 min=0.008634300 median=0.008703400 max=0.009174400 mean=0.008844500

Raw sample variation (max − min): 0.000540100 s (~6.1% of mean)

## Limitations

- Local Windows x64 only; Linux CI hosts were not measured in this capture
- No network I/O, TLS, broker, or multi-connection workload
- Short representative inputs only; not a general PUBLISH size sweep
- Results vary with background load, power policy, and toolchain upgrades
- Do not treat these numbers as release criteria or universal speed claims
- This note does **not** by itself complete M0
