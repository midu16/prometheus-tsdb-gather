# Selective + Size-Safe TSDB Gather (gather v1.4.0)

How to drive the new safeguard / time-window / retention / compression
features **from the `oc adm must-gather` command itself** — no wrapper needed.

Spec: [`../features/safeguard-size-selective-export.md`](../features/safeguard-size-selective-export.md)

---

## The one command

The exact call you use to run the extract:

```bash
export KUBECONFIG=/var/apps/sno.frntdeu1.pop.starlinkisp.net/workdir/auth/kubeconfig
oc adm must-gather \
    --image=quay.io/midu/prometheus-tsdb-gather:v6 \
    --dest-dir $(pwd)/demo-run
```

That's the whole story for a **full, size-guarded, compressed** export. The
flags below are **optional** and, when present, go **after a `--`** — the
must-gather framework passes everything after `--` as the container command,
so it lands as the argument list of `/usr/bin/gather` inside the pod:

```bash
oc adm must-gather \
    --image=quay.io/midu/prometheus-tsdb-gather:v6 \
    --dest-dir $(pwd)/demo-run \
    -- /usr/bin/gather <gather-flags>
```

### Why the `-- /usr/bin/gather` prefix

| No `--` | With `-- /usr/bin/gather` |
|---------|---------------------------|
| framework runs the image's default entrypoint, i.e. `/usr/bin/gather` with **no args** → full export with image defaults | you supply the exact command **and** its flags, so `--since`/`--max-size`/etc. take effect |

For a plain full export the two forms are equivalent. Add `-- …` only when you
want to change a default.

### Authentication (no secret, no wrapper)

`gather` looks for an injected kubeconfig at
`/etc/must-gather-kubeconfig/kubeconfig`. When you run the **raw** command
there is no such file (only the wrapper creates it), so `gather` **falls back
to the framework's in-cluster cluster-admin service account** and logs:

```
[gather] Auth: no kubeconfig at /etc/must-gather-kubeconfig/kubeconfig - using in-cluster SA credential (user: system:serviceaccount:openshift-must-gather-…:default)
```

The must-gather pod is cluster-admin-bound, so this works out of the box. Use
[`../run-must-gather.sh`](../run-must-gather.sh) only if you specifically want
your *own* kubeconfig (as a least-priv Secret) inside the gather pod — it sets
the same flags via env vars.

---

## Flags (everything `gather` accepts, all optional)

```text
Size safeguard (pre-flight gate, BEFORE any byte is copied):
  --max-size <size>       projected-export budget: bytes, 512Mi, 2Gi, … (default 2Gi; 'none' = off)
  --size-policy fail|warn fail = abort pre-copy with FATAL (default);  warn = log + continue

Time-window export (selective, block-granular, source-side):
  --since <ts>            inclusive lower bound (default: oldest block)
  --until <ts>            inclusive upper bound (default: now)
  --include-wal true|false|auto   copy WAL+chunks_head (default auto: on when --until is within 1h of now)

Compression (after extraction, CPU-bound, cheap):
  --compress none|zstd|gzip   archive the extracted copy (default: zstd)

  <ts> = RFC3339 (2026-10-02T20:00:00Z), Prometheus-relative (6h, 2d, 3d12h, 90m),
         anything GNU date parses ("24 hours ago"), unix seconds, or 'now'.
```

The equivalent env vars (`MAX_GATHER_BYTES`, `SIZE_POLICY`, `SINCE`, `UNTIL`,
`INCLUDE_WAL`, `COMPRESS`) are forwarded by `run-must-gather.sh` if you use it;
the flags above are the direct, no-wrapper form.

---

## What you get in `--dest-dir`

```
demo-run/
├── event-filter.html
├── must-gather.logs                        # framework (rsync) log
├── timestamp
└── quay-io-midu-prometheus-tsdb-gather-sha256-<digest>/   # payload
    ├── version                             # "prometheus-tsdb-must-gather" / "1.4.0"
    ├── gather.log                          # the full in-cluster run log (read FATAL/WARN here)
    ├── whoami.txt
    ├── prometheus-snapshot/
    │   ├── <UTC-ts>/                       # the TSDB tree: <ULID> block dirs + wal/ + chunks_head/
    │   ├── <UTC-ts>.tar.zstd               # compressed copy (COMPRESS=zstd default)
    │   └── SHA256SUMS
    └── prometheus-metadata/
        ├── size-budget.txt                 # projected vs budget, policy, decision
        ├── time-window.json                # since/until + included/excluded blocks
        ├── retention.txt                   # effective retention + data bounds
        ├── block-inventory.tsv             # per-block ULID, min/max time, size
        ├── compression.txt                 # ratio, sha256, the exact unpack command
        ├── tsdb-verify.txt                 # in-cluster promtool tsdb list
        ├── tsdb-analyze-newest.txt         # promtool tsdb analyze (newest block)
        ├── tsdb-local-struct.txt           # local copy structural check
        └── … (node/pod JSON, config, describe, log tail)
```

Locate the payload (the dir name carries the image digest, not the tag):

```bash
P=$(find demo-run -maxdepth 1 -type d -name 'quay-io-*prometheus-tsdb-gather*' | head -1)
```

> **Read `gather.log` for the verdict.** `oc adm must-gather` returns exit **0
> even when `gather` hits a `FATAL`** — the framework does not propagate the
> payload's exit code. Grep the log:
>
> ```bash
> grep -E 'FATAL|DONE - mode=' "$P/gather.log"
> ```

---

## Recipes (all verified against this cluster, 2026-10-03)

### 1. Full export, size-guarded, compressed (default)

```bash
oc adm must-gather --image=quay.io/midu/prometheus-tsdb-gather:v6 --dest-dir $(pwd)/demo-run
```

Observed (cluster TSDB ≈ 940 MiB):

```
Window:  selected 5 of 5 blocks; …  excluded=[(none)]  wal_included=1
Budget:  projected 942.6 MiB <= budget 2Gi (2147483648 bytes) (policy=fail) - allowed
Compression done: 3s raw=988447639B archive=267887033B ratio=0.271
DONE - mode=direct; … archive=20261003T114028Z.tar.zstd
```

`size-budget.txt` → `decision=allow`. Unpack if you only want the archive:

```bash
tar -I zstd -xf "$P/prometheus-snapshot/20261003T114028Z.tar.zstd" -C out/
```

### 2. Export only the last 16 h (size reduction)

```bash
oc adm must-gather … --dest-dir $(pwd)/demo-run -- /usr/bin/gather --since 16h
```

Observed: 2 of 5 blocks kept, 962 → 652 MiB.

```
Window: selected 2 of 5 blocks; selected=[01M40E8T5Z19KDAAS80R14A0M3 01M40RHFRQE1E1F7E0F13C7BMP]
        excluded=[01M3YSAEYX0Y4VJ1TPEG2ANAT6 01M40E8P1QKMJT6A716F50BJ7Q 01M40E8ZM5BZJ5NNNS0EQZMV0Q]
time-window.json → blocks_excluded: [3 ULIDs], notes: "Excluded blocks outside window to reduce gather size"
```

Excluded blocks **never leave the pod**. Playback queries outside the window
return empty — set Grafana's time range to `[since, until]`.

### 3. Cap by size and *hard-fail* before copying

```bash
oc adm must-gather … --dest-dir $(pwd)/demo-run -- /usr/bin/gather --max-size 100Mi
```

Observed: **nothing is copied**, a stable machine-grepable block is emitted,
`size-budget.txt` → `decision=deny`:

```
FATAL: projected must-gather TSDB export exceeds size budget
  projected=962MiB  budget=100.0 MiB  policy=fail
  mode=snapshot  blocks_selected=5/5  window=0 since=(oldest) until=now
  hint: narrow the window with --since/--until (or SINCE/UNTIL),
        raise MAX_GATHER_BYTES (or --max-size), or free space on the gather volume / --dest-dir
  see: prometheus-metadata/size-budget.txt
```

To log-and-continue instead: add `--size-policy warn`.

### 4. Window older than the data on disk (now clamps, no longer a hard fail)

```bash
oc adm must-gather … --dest-dir $(pwd)/demo-run -- /usr/bin/gather --since 30d --until 29d
```

As of **v1.4.0** a window that selects **zero** blocks is no longer a hard
error. Typical cause: retention already GC'd the requested period. The gather
now **clamps** the window to the available data bounds and ships the closest
snapshot the cluster can still produce, warning loudly:

```
WARN: requested window [30d .. 29d] does not intersect ANY TSDB block on disk
  oldest_block=2026-10-02T07:36:50Z  newest_block=2026-10-03T12:00:00Z
  exporting the closest available data instead (clamped window); retention_hint=see prometheus-metadata/retention.txt
Window: selected 4 of 4 blocks; … clamped=1 effective=[2026-10-02T07:36:50Z .. 2026-10-03T12:00:00Z]
```

The clamp is recorded in `time-window.json` (`window_clamped:true` +
`original_request`) and `retention.txt`
(`window_vs_data=request_disjoint_clamped_to_available` /
`requested_since_newer_than_oldest_block`).

### 5. Uncompressed export (compare / no zstd on the node)

```bash
oc adm must-gather … --dest-dir $(pwd)/demo-run -- /usr/bin/gather --compress none
```

Ships the unpacked `<UTC-ts>/` tree only, no `*.tar.zstd`. `compression.txt`
records `status=skipped (COMPRESS=none)`.

---

## The four capabilities, where they show up

| Capability | Gate / step when | Evidence in output |
|------------|------------------|--------------------|
| **1. Size safeguard** | pre-flight, *before* any copy | `size-budget.txt` (`decision=allow\|deny`), `FATAL: projected must-gather TSDB export exceeds size budget` |
| **2. Time-window export** | pre-flight (select) + extract (copy selected only) | `time-window.json` (`window_clamped`, `original_request`), `Window: selected N of M blocks … clamped=0/1`, `WARN: requested window [..] does not intersect ANY TSDB block on disk` |
| **3. Retention awareness** | always | `retention.txt` (`retention_effective`, data bounds, `window_vs_data`); **Tier A+B only** — live retention patching is intentionally **not** implemented |
| **4. Compression** | post-extract (local, CPU) | `compression.txt` (ratio, sha256, unpack cmd), `<ts>.tar.zstd` + `SHA256SUMS` |

---

## Playback (opening the extracted data offline)

The archive is for **transfer/storage**; the **unpacked tree** is what a
standalone Prometheus opens.

```bash
P=$(find demo-run -maxdepth 1 -type d -name 'quay-io-*prometheus-tsdb-gather*' | head -1)
TS=$(ls -d "$P/prometheus-snapshot"/*/ | head -1)          # the unpacked tree
# if you only kept the archive:
#   tar -I zstd -xf "$P/prometheus-snapshot/"*.tar.zstd -C /tmp/tsdb-out && TS=/tmp/tsdb-out/
# mount "$TS" at /prometheus in a `prom/prometheus:v3.x` container; it replays
# the WAL on startup (worst-case loss = torn tail of the newest in-flight
# WAL segment, see `retention`/gather notes). Queries outside [since,until]
# are empty — set Grafana's range to the exported window.
```

`compression.txt` prints the exact unpack line for the archive it produced, e.g.
`unpack=tar -I zstd -xf 20261003T114028Z.tar.zstd -C <newdir>`.

Verify integrity without a cluster:

```bash
(cd "$P/prometheus-snapshot" && sha256sum -c SHA256SUMS)
```

---

## Troubleshooting (rows actually observed)

| Symptom | Cause / fix |
|---------|-------------|
| `FATAL: projected must-gather TSDB export exceeds size budget` | Budget gate, nothing copied. `--since/--until` to narrow, `--max-size` to raise, or `--size-policy warn` to continue. See `size-budget.txt` |
| `WARN: requested window [..] does not intersect ANY TSDB block on disk` | Window outside data on disk (retention deleted it). **v1.4.0: no longer fatal** — the window is clamped to the available data and the closest snapshot is exported. Check `retention.txt` + `time-window.json` (`window_clamped`, `original_request`) to confirm what was really shipped |
| `WARN: remote tar hit the expected live-WAL torn-tail error` | **Expected, not a failure.** The WAL is appended while read; copy stays crash-consistent, re-opening Prometheus replays it. Loss ≤ torn tail of newest in-flight segment |
| `oc adm must-gather` exits 0 but `gather.log` has `FATAL` | Framework does **not** propagate the payload exit code. Always grep `gather.log` for `FATAL`/`DONE - mode=` |
| `prometheus-snapshot/<ts>.tar.zstd` present but playback empty | Archive is transfer-only: unpack first (`tar -I zstd -xf … -C dir`), point the prom mount at the **unpacked** tree |
| Ran the **old** script (v1.1.0, no size/window metadata) | Node CRI-O cached the tag. Push a **new image** then evict the node cache: `oc debug node/master-0 -- chroot /host crictl rmi quay.io/midu/prometheus-tsdb-gather:v6` |
| `zstd compression failed - keeping the unarchived tree only` | Pre-`zstd` image. Rebuild (now `dnf -y install zstd`), or `--compress gzip`/`none` |
| `mode=snapshot` vs `mode=direct` | Direct is the verified path on this cluster (admin API disabled on Prometheus 3.13). Both yield the same crash-consistent tree; direct writes nothing to the pod |
