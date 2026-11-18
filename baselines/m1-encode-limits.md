# M1 encode limit vectors (local)

Independent OASIS MQTT 3.1.1-derived `encode_publish` boundary checks for the
65 535-byte topic limit and Remaining Length at / above `MAX_REMAINING`
(268 435 455). Expected header / length / identifier bytes are asserted before
any round trip; topic and payload bytes are compared; failure paths leave
caller-owned output untouched.

## Ordinary suite (topic length)

File: `tests/publish_encode.goose` → `topic_length_limits()`

| Case | Expected |
|------|----------|
| Topic len 65535, QoS 0, empty payload | `OK`, n=65541; header `30 81 80 04 ff ff`; topic equals input |
| Same inputs, out len 65540 | `NO_SPACE`, n=0, sentinel unchanged |
| Topic len 65536 | `INVALID`, n=0, sentinel unchanged |

Allocation: heap `u8[>..]` (~64 KiB topic + ~64 KiB out). Included in
`python scripts/test.py`.

## Opt-in stress (Remaining Length)

File: `tests/publish_encode_maxrl.goose` (not in `scripts/test.py`)

| Case | Expected |
|------|----------|
| Topic `"a"`, payload len `MAX_REMAINING-3` | `OK`, n=`5+MAX_REMAINING`; header `30 ff ff ff 7f 00 01 61`; payload equals input |
| Same inputs, out len `need-1` | `NO_SPACE`, n=0, sentinel unchanged |
| Payload len `MAX_REMAINING-2` (RL = max+1) | `INVALID`, n=0, sentinel unchanged |

Expected peak heap ≈ **512 MiB** (payload 268 435 452 + out 268 435 460).

```sh
goose tests/publish_encode_maxrl.goose
goose --debug tests/publish_encode_maxrl.goose
goose build tests/publish_encode_maxrl.goose   # then run the native binary
```

## Local results

Goose: v2026.4. Host date: 2026-11-18. Branch base: `41eff8f` (main).

### Windows (win32 10.0.26300, x64; clang 14.0.6)

| Check | Result |
|-------|--------|
| `python scripts/lint.py` | pass |
| `python scripts/test_selftest.py` | pass |
| `python scripts/test.py` | pass (includes topic 65535/65536) |
| `python scripts/test.py --native --require-native` | pass |
| `goose tests/publish_encode_maxrl.goose` | pass (~2.4s) |
| `goose --debug tests/publish_encode_maxrl.goose` | pass |
| `goose build` + `tests/publish_encode_maxrl.exe` | pass |

### Ubuntu WSL2 x64 (`Ubuntu-24.04`; gcc 13.3.0; goose under `/root/goose-v2026.4/...`)

Tree synced from the Windows worktree into `/root/honkmqtt-m1-limits` (WSL cannot
use the Windows Goose on PATH). Same checklist:

| Check | Result |
|-------|--------|
| `python3 scripts/lint.py` | pass |
| `python3 scripts/test_selftest.py` | pass |
| `python3 scripts/test.py` | pass (includes topic 65535/65536) |
| `python3 scripts/test.py --native --require-native` | pass |
| `goose tests/publish_encode_maxrl.goose` | pass |
| `goose --debug tests/publish_encode_maxrl.goose` | pass |
| `goose build` + `./tests/publish_encode_maxrl` | pass |

## Remaining M1 gap

Optimized-build `encode_publish` performance baseline (M1 Exit) is still open;
limit-vector evidence above does not close that item.
