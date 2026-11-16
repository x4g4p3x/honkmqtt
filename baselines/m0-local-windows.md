# M0 local optimized-build baselines (Windows x64)

Recorded local baseline for HonkMQTT M0. This is a single-machine snapshot,
not a CI SLA, product throughput claim, or cross-platform ranking. M0 is not
marked complete from this capture alone (Linux host baselines remain a gap).

## Source and commands

| Pin | Value |
| --- | --- |
| Branch | `ao/m0-roadmap/m0-perf-baselines` |
| Measurement identity | SHA-256 of git blobs for library + benchmark sources (table below) |
| Command | `python scripts/bench.py --warmup 1 --samples 7` |

**SHA-256 of git blob bytes** (filled for the freeze commit that contains these
measured sources; verify with `git show <freeze>:path | sha256sum`):

| Path | SHA-256 | Size |
| --- | --- | --- |
| `honkmqtt.goose` | `PENDING_FREEZE` | |
| `tests/bench_publish.goose` | `PENDING_FREEZE` | |
| `tests/benchmark.goose` | `PENDING_FREEZE` | |
| `scripts/bench.py` | `PENDING_FREEZE` | |

Freeze commit: `PENDING_FREEZE` (set in the docs pin commit after the workload
freeze lands).

Reproduce:

```sh
python scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 <workload.goose>` (scripted)
- Timing boundary: `steady_seconds` from Goose `clock()` around the timed loop
  only; process startup and one warmup run are excluded from recorded samples
- Correctness: each sample must print the expected checksum; the runner fails
  otherwise. Expected totals are computed independently of `honkmqtt::publish` /
  timed encode calls before the timed loop
- Samples: serialized; warmup discarded; seven recorded samples per workload

## Anti-elision

- **Runtime-dependent packet bytes:** each iteration copies a case template then
  writes loop-index-derived values into payload / packet-id-low / topic bytes
  (`mutate_runtime` / `mutate_body` / `mutate_match_topic`). Double-XOR no-op
  salts were removed after review
- **Independent expected outputs:** checksum expectations are computed in a
  separate pre-timed path that does not call the timed `publish`/`encode` APIs;
  the timed loop aborts if parsed/encoded fields disagree
- **Argv:** `tests/benchmark.goose` rejects legacy body/filter/topic arguments so
  callers cannot mistake multi-case timings for a requested single workload
- **Final optimized assembly (clang `-O2` of Goose `-O2` C):**
  - `publish_parse` timed loop stores runtime bytes (e.g. `movb %r12b, …(%rbp)`)
    then `callq honkmqtt_publish_g8`
  - `encode_frame_match` timed loop mutates body bytes then inlines encode/frame
    work and `callq honkmqtt_matches_g8`

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
- Cases (3) with per-iteration body and match-topic mutations
- Iterations: 1_000_000
- Expected checksum: `138498139`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.051043100 | 100 |
| 2 | 0.050569700 | 100 |
| 3 | 0.047492600 | 100 |
| 4 | 0.049576500 | 100 |
| 5 | 0.045816600 | 100 |
| 6 | 0.060247700 | 100 |
| 7 | 0.049535500 | 100 |

Summary: n=7 min=0.045816600 median=0.049576500 max=0.060247700 mean=0.050611671

Raw sample variation (max − min): 0.014431100 s (~28.5% of mean)

## Workload: `publish_parse`

- Source: `tests/bench_publish.goose`
- Cases (4) with per-iteration payload / id-low / topic mutations
- Iterations: 1_000_000
- Expected checksum: `17675999524`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.008334000 | 100 |
| 2 | 0.009048200 | 100 |
| 3 | 0.008802400 | 100 |
| 4 | 0.008905800 | 100 |
| 5 | 0.008402500 | 100 |
| 6 | 0.008385800 | 100 |
| 7 | 0.008336800 | 100 |

Summary: n=7 min=0.008334000 median=0.008402500 max=0.009048200 mean=0.008602214

Raw sample variation (max − min): 0.000714200 s (~8.3% of mean)

## Limitations

- Local Windows x64 only; Linux CI hosts were not measured in this capture
- No network I/O, TLS, broker, or multi-connection workload
- Short representative inputs only; not a general PUBLISH size sweep
- Results vary with background load, power policy, and toolchain upgrades
- Do not treat these numbers as release criteria or universal speed claims
- This note does **not** by itself complete M0
