# gather test suite

Tests for the must-gather payload `../gather` (Prometheus TSDB extraction).
Everything runs the REAL shipped script or code extracted verbatim from it -
no copies of the logic.

## Layers

| suite | what it runs | cluster needed |
|---|---|---|
| `test-01-usage.sh` | `--help`/`-h` contract incl. `--limit <size> [default: 4GB, 0: unlimited]` | no |
| `test-02-flag-parsing.sh` | **every flag**, valid + invalid, flag and env forms (exit 64 rejections with stable messages; acceptances prove the combo survives validation). Includes the production combos `--since 30d --until 29d --limit 1234GB` and `--limit 0` | no (rejections exit before any cluster access; acceptances stop at pre-flight via a bogus pod - side-effect-free) |
| `test-03-human-size.sh` | `human_size_to_bytes`: `0/512/1K/4KB/100Mb/500MB/4GB/1234GB/1T/2TB/1KiB/512Mi/2Gi/3Ti/none/off/unlimited/...` + invalid | no |
| `test-04-timestamps.sh` | `parse_ts_seconds`: Prometheus letter durations (`30d`, `6h`, `90m`, `12s`, `1w`, `3d12h`), RFC3339, GNU prose (`24 hours ago`), epoch, `now`; since>until rejection | no |
| `test-05-limit-monitor.sh` | the v1.6.0 `--limit` extraction block with a stubbed `oc` producing real tar streams from a fake remote: **pre-transfer halt**, **mid-transfer breach** (pipeline killed, partial member dropped, exit 0, `limit-halt.txt`), **under-cap** byte-identical copy, **fail-retry-once-then-FATAL**, **live-WAL torn-tail** classification | no |
| `test-06-e2e-must-gather.sh` | the **production invocation** per flag case against the live cluster (below) | **yes** (self-skips + exit 0 without one; `E2E_REQUIRED=1` hard-fails) |

## Running

```bash
./tests/run-all.sh                # everything; E2E skips itself without a cluster
./tests/run-all.sh --unit-only    # offline development (no oc/cluster at all)
./tests/run-all.sh --e2e-only     # live matrix on the operator workstation
bash tests/test-02-flag-parsing.sh   # a single suite
```

## E2E prerequisites (test-06)

1. **Image built from THIS checkout** - the image's payload must report
   version `1.6.0` (the `version` file, line 2) or cases fail with
   `unknown flag: --limit`. Rebuild + push:

   ```bash
   podman build -t quay.io/midu/prometheus-tsdb-gather:latest -f Containerfile .
   podman push quay.io/midu/prometheus-tsdb-gather:latest
   ```

2. **A reachable cluster + operator kubeconfig** for the client `oc`
   (payload pod authenticates via its in-cluster cluster-admin SA, so no
   kubeconfig-injection wrapper is needed):

   ```bash
   export E2E_KUBECONFIG=/var/apps/sno.frntdeu1.pop.starlinkisp.net/workdir/auth/kubeconfig
   ./tests/run-all.sh --e2e-only
   ```

3. Tunables: `E2E_IMAGE` (image ref), `E2E_DEST` (output root, default
   `tests/.e2e-out/`), `E2E_TIMEOUT` (per-run framework timeout, default 25m).
   Quick subset (cases 01-04): `E2E_QUICK=1 ./tests/run-all.sh --e2e-only`
   (extend via `E2E_QUICK_CASES="01 04 07"`).

## E2E case matrix

| id | flags | verifies |
|---|---|---|
| 01 | *(defaults)* `--max-size none` | full export; default `--limit 4GB` in play; snapshot tree, `time-window.json`, `window_active=0` |
| 02 | `--since 30d --until 29d` | the production window; `window_active=1`, `retention.txt` |
| 03 | `--limit 0` | unlimited: `limit_active=0`, no halt record |
| 04 | `--limit 1Mi` | **guaranteed breach**: framework rc **0** (no container crash), `limit-halt.txt` with `halt_reason`, partial in-flight member dropped, remaining blocks structurally valid |
| 05 | `--compress none` | no `.tar.*` archive shipped |
| 06 | `--max-size 1MB --size-policy warn` | budget deny + warn-and-continue, run still DONE |
| 07 | `--max-size 1MB` (fail policy) | pre-flight FATAL **before any copy**; nothing ships; framework rc != 0 |
| 08 | `--include-wal false` | no `wal/` dir in the export |
| 09 | `--strict-notready` | strict gate recorded, healthy cluster still runs |
| 10 | `--max-gb 100 --at "2 days ago"` | legacy post-copy guards recorded (`export-guards.txt`) |
| 11 | `--since 30d --until 29d --limit 1234GB` | the operator's EXACT production invocation (incl. default 2Gi budget gate + recorded `limit_bytes`) |
| 12 | `--compress gzip` | `.tar.gz` archive shipped; `sha256sum -c SHA256SUMS` passes |
| 13 | `--include-wal true` | `wal/` dir ships, `include_wal=true` recorded |

Every case additionally asserts: payload dir present, `version` =
`prometheus-tsdb-must-gather/1.6.0`, and **no kubeconfig/credential leak**
into the shipped payload.

Outputs land in `tests/.e2e-out/<case>/` (git-ignored): `framework.log`
(client side) + the framework's downloaded `must-gather` tree.

## Exit codes

* unit suites: 0 = all green, 1 = any FAIL (SKIP allowed)
* test-06 without a cluster: 0 (SKIP), 1 with `E2E_REQUIRED=1`
* flag-validation failures in the payload: 64, hard failures: 1,
  clean limit-halt: **0** (by contract - the must-gather pod must finish)
