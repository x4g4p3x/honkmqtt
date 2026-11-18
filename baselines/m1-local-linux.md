# M1 local optimized-build `encode_publish` baseline (Linux x64 / WSL2)

Local Linux x64 capture for the M1 `publish_encode` workload using the same
sources and expected checksum as `baselines/m1-local-windows.md`. Environment is
**Ubuntu 24.04 LTS under WSL2** (not bare-metal CI). Single-machine snapshot;
not a CI SLA or universal speed claim. No cross-platform performance ranking.

## Source and commands

| Pin | Value |
| --- | --- |
| Measurement commit | `a38b0aade5cdcd71fb9c4f8dde3b3399b04cfa77` |
| Base main | `4203d37add9473b44af35ac0a040e46973000349` |
| Distro | `Ubuntu-24.04` (WSL2) |
| Command | `python3 scripts/bench.py --warmup 1 --samples 7` |
| Working copy | Tree synced into `/root/honkmqtt-m1-baselines` for build/exec |

**Identity:** SHA-256 of git blob bytes at `a38b0aa` (same as Windows capture):

| Path | SHA-256 | Size |
| --- | --- | --- |
| `honkmqtt.goose` | `67dc6135d1345206d30f4e94f3bf1bda8c7837a615dd7767da8d2cb190af2aeb` | 9611 |
| `tests/bench_encode_publish.goose` | `ce4ee2b39dc882eb54a9d4b4f8585c0e0adc11b72a218b7dd465e963ca17e8ee` | 5701 |
| `scripts/bench.py` | `89d2ecd85462f7a7e23481af5d0a7d628751385d94887cc8cad6229ee7a9a265` | 7325 |

Manifest SHA-256 (three `hash  path` lines, LF-separated):
`d0e1fb8e2634a9ba2554809672265ef27e649c6d12adcc3bcd61edbd82ac022c`

Reproduce (Ubuntu-24.04 WSL2, Goose linux-x64 v2026.4, gcc on PATH):

```sh
python3 scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 tests/bench_encode_publish.goose`
- Timing boundary: loop-only `steady_seconds`; one warmup discarded; seven
  serialized samples
- Correctness: checksum must equal `17860248136` (matched Windows capture)

## Machine and toolchain

| Field | Value |
| --- | --- |
| Host | `MartinPC` (WSL2 guest) |
| `uname -a` | `Linux MartinPC 6.18.58.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Tue Oct 27 00:24:11 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux` |
| Distro | Ubuntu 24.04 LTS (`Ubuntu-24.04`), WSL version 2 |
| Goose | v2026.4 linux-x64, runtime `dce889723a23` |
| C compiler | gcc 13.3.0 (`/usr/bin/cc`; `goose toolchain` id `gcc-13.3.0-a920ca84`) |
| Python | 3.12.3 |
| Clock resolution probe | `clock_res_ns=9` on every sample |

## Workload: `publish_encode`

- Expected checksum: `17860248136` (same as Windows; functional equivalence)

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.011954693 | 9 |
| 2 | 0.011844019 | 9 |
| 3 | 0.012999883 | 9 |
| 4 | 0.013938330 | 9 |
| 5 | 0.011564934 | 9 |
| 6 | 0.011393651 | 9 |
| 7 | 0.011353013 | 9 |

Summary: n=7 min=0.011353013 median=0.011844019 max=0.013938330 mean=0.012149789

Raw sample variation (max − min): 0.002585317 s (~21.3% of mean)

## Limitations

- WSL2 guest, not bare-metal Linux CI hardware
- Same short representative inputs as Windows; no network I/O
- Timings are not compared to Windows as a performance claim; checksum equality
  is the cross-platform equivalence check
- Scoped to M1 `encode_publish` baseline evidence
