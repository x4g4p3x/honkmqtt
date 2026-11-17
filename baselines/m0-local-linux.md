# M0 local optimized-build baselines (Linux x64 / WSL2)

Local Linux x64 capture for HonkMQTT M0 using the same workloads as
`baselines/m0-local-windows.md`. Environment is **Ubuntu 24.04 LTS under
WSL2** (not a bare-metal CI runner). This is a single-machine snapshot, not a
CI SLA or universal speed claim.

## Source and commands

| Pin | Value |
| --- | --- |
| Immutable Git revision for measured blobs | `58c7745c7e0819246eddb725f78b26a597bb15bb` (`main` after PR #4; on `origin`) |
| Distro | `Ubuntu-24.04` (WSL2), installed via `wsl --install Ubuntu-24.04 --no-launch --web-download` when no distros were registered |
| Command | `python3 scripts/bench.py --warmup 1 --samples 7` |
| Working copy | Tree from that revision copied into the Linux filesystem (`/root/honkmqtt-linux-baselines`) for build/exec |

**Identity:** SHA-256 of **git blob bytes** at `58c7745` (`git show 58c7745:path`).
Goose sources are LF in the repository. On Windows checkouts with
`core.autocrlf=true`, working-tree `scripts/bench.py` may be CRLF (different
SHA-256 / size); Linux/WSL and `git show` use the LF blob. Measurement used LF
bytes on ext4, matching:

| Path | SHA-256 (git blob / LF) | Size |
| --- | --- | --- |
| `honkmqtt.goose` | `fd26625e9203d50090387fce1ce3f2d20a82a016c18934aadeb3dea3a89708f6` | 7033 |
| `tests/bench_publish.goose` | `daa494862aedf78f0a124722d4cecfd80057067124b56fc154aeeaf352635199` | 4851 |
| `tests/benchmark.goose` | `27983bc233e674d4b44741aac79bea8166525d54de50c0231d2ea2948d7b6c33` | 5352 |
| `scripts/bench.py` | `6d3e5b1cd35c2bdc42a6e1074a56992ad82199dd0bc1d81626a293eba1e643be` | 7053 |

Manifest SHA-256 (four `hash  path` lines, LF-separated):
`bb36a45d1c4cbcd568ffc1ec1bab1fc0bbedd8cf2d59d328b573a3eac3d42bcd`

Same manifest as the Windows baseline freeze for these four paths.

Reproduce (inside Ubuntu-24.04 WSL2 with Goose linux-x64 v2026.4 and gcc on
PATH), from an immutable checkout of `58c7745` or any later tip whose four
blobs still match the hashes above:

```sh
git switch --detach 58c7745c7e0819246eddb725f78b26a597bb15bb
python3 scripts/bench.py --warmup 1 --samples 7
```

- Build: `goose build -O2 <workload.goose>`
- Timing boundary: loop-only `steady_seconds` from Goose `clock()`; one warmup
  discarded; seven serialized samples
- Correctness: checksums must match expected totals (`138498139` /
  `17675999524`)

## Machine and toolchain

| Field | Value |
| --- | --- |
| Host | `MartinPC` (WSL2 guest) |
| `uname -a` | `Linux MartinPC 6.18.58.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Tue Oct 27 00:24:11 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux` |
| Distro | Ubuntu 24.04 LTS (`Ubuntu-24.04`), WSL version 2 |
| WSL package | 3.0.5.0 |
| Goose | v2026.4 linux-x64 (archive SHA-256 `559ad7572df89fcd1273512d8679528bcdf876c252ec1f31608d3808b24125b3`), runtime `dce889723a23` |
| C compiler | gcc 13.3.0 (`/usr/bin/cc`; `goose toolchain` id `gcc-13.3.0-a920ca84`) |
| Python | 3.12.3 |
| Clock resolution probe | `clock_res_ns=9` on every sample |

## Workload: `encode_frame_match`

- Expected checksum: `138498139`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.046819152 | 9 |
| 2 | 0.046643169 | 9 |
| 3 | 0.046369545 | 9 |
| 4 | 0.046454298 | 9 |
| 5 | 0.046496911 | 9 |
| 6 | 0.046447622 | 9 |
| 7 | 0.046926293 | 9 |

Summary: n=7 min=0.046369545 median=0.046496911 max=0.046926293 mean=0.046593856

Raw sample variation (max − min): 0.000556748 s (~1.2% of mean)

## Workload: `publish_parse`

- Expected checksum: `17675999524`

Raw `steady_seconds` after warmup:

| Sample | steady_seconds | clock_res_ns |
| --- | --- | --- |
| 1 | 0.009749451 | 9 |
| 2 | 0.009616486 | 9 |
| 3 | 0.009681250 | 9 |
| 4 | 0.009608013 | 9 |
| 5 | 0.009645145 | 9 |
| 6 | 0.009590306 | 9 |
| 7 | 0.009629028 | 9 |

Summary: n=7 min=0.009590306 median=0.009629028 max=0.009749451 mean=0.009645668

Raw sample variation (max − min): 0.000159145 s (~1.6% of mean)

## Verification on this environment

Also on the same Linux copy before timing: `python3 scripts/lint.py` and
`python3 scripts/test.py --native --require-native` passed (interpreter
normal/debug + native gcc builds).

## Limitations

- **WSL2**, not bare-metal `ubuntu-24.04` GitHub Actions hardware; timings are
  not interchangeable with CI host microbenchmarks
- Short representative inputs; no network I/O
- Shared Windows host CPU/memory; results vary with background load
- Not a throughput SLA or safety claim
