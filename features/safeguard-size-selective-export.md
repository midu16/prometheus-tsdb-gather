# Feature: Safeguard must-gather size, selective time export, retention, and compression

| Field | Value |
| --- | --- |
| **Status** | Done (shipped, gather v1.3.0 — see Outcomes below) |
| **Type** | Feature / Enhancement |
| **Priority** | High |
| **Affected components** | `gather`, `run-must-gather.sh`, must-gather output contract, playback docs |
| **Related area** | OpenShift must-gather, Prometheus TSDB forensics |
| **Created** | 2026-10-02 |
| **Implemented** | 2026-10-03 |
| **Operator guide** | [`docs/selective-size-safe-gather.md`](../docs/selective-size-safe-gather.md) |
| **Labels** | `enhancement`, `must-gather`, `tsdb`, `size-budget`, `cli-flags` |

---

## Summary

Today the gather payload copies the **entire** live Prometheus TSDB (or a full admin-API snapshot). On real clusters that payload is often ~1 GiB and can grow with retention. There is **no hard size guard**, **no way to export only a time window**, **no retention-aware guidance**, and **no measured compression strategy** for shipping the archive.

This feature proposes four tightly related capabilities:

1. **Safeguard must-gather size** — enforce a configurable budget and **fail fast with a clear error** before a runaway copy fills the gather volume or the operator workstation.
2. **Time-window export flags** — let operators export only blocks (and, where needed, WAL) that cover a given `[start, end]` period.
3. **Retention awareness** — detect and, where safely possible, document or temporarily adjust retention so the exported window is actually present on disk.
4. **Compression investigation** — measure whether compressing the Prometheus TSDB (or selected blocks) reduces must-gather transfer size enough to justify the CPU/time cost.

---

## Motivation

### Problem

| Pain point | Current behavior | Impact |
| --- | --- | --- |
| Unbounded TSDB copy | `oc cp` of `/prometheus` (MODE=`direct`) or full snapshot | Gather pods hit `--volume-percentage` limits; downloads stall; operator disks fill |
| Weak failure signal | Size is logged (`Live TSDB size: N MiB`) but copy still proceeds | Failures appear late as opaque `oc cp` / rsync / disk-full errors |
| No scoped forensics | Always copies all compacted blocks + WAL | Incident windows of hours still pull days/weeks of history |
| Retention mismatch | Cluster retention may be shorter or longer than the window the user needs | Empty or incomplete exports; no pre-flight explanation |
| Unknown compression ROI | Offline transfer of raw ULID dirs is uncompressed | Potentially wasteful bandwidth and dest-dir footprint |

### Why now

- Verified runs already show ~1 GiB TSDBs on SNO; production multi-day retention will be larger.
- The gather script already inventories blocks and records size (`du -sk`) — the hooks for budgeting and selection exist but are unused as gates.
- `promtool tsdb list` already exposes per-block time bounds suitable for window filtering.

### Goals

- [ ] Abort (or warn, per policy) when the projected export exceeds a size budget, with an **actionable error message**.
- [ ] Support CLI/env flags to export only data covering a time range.
- [ ] Surface cluster retention in pre-flight and document whether changing it is feasible for this toolkit.
- [ ] Produce an evidence-based recommendation on compressing TSDB data before/during must-gather transfer.
- [ ] Keep the must-gather contract intact: writable output under `/must-gather`, no secrets in the tree, clear `version` + metadata.

### Non-goals

- Changing the OpenShift must-gather framework itself (`oc adm must-gather` volume semantics).
- Permanently mutating production Prometheus retention as part of a normal gather (any retention change must be opt-in, explicit, and reversible).
- Replacing Prometheus’s own block format or implementing a custom TSDB writer.
- Guaranteeing zero sample loss for partial-window `MODE=direct` copies of the head/WAL (document residual risk instead).

---

## User stories

1. **As an SRE**, I want the gather to **refuse** to copy a multi-gigabyte TSDB when my dest disk or gather volume cannot hold it, and I want the log to tell me **why** and **what to do next**.
2. **As an SRE**, I want to export **only the last 6 hours** (or an incident window) so the must-gather stays small and reviews finish faster.
3. **As a platform engineer**, I want to know the cluster’s **effective retention** before I request a 7-day window that the PVC no longer holds.
4. **As a maintainer**, I want measured data on **gzip/zstd/tar** of TSDB blocks vs raw `oc cp` so we ship the cheapest safe default.

---

## Proposed design

### 1. Safeguarding must-gather size + error messages

#### Behavior

1. **Pre-flight budget check** (extend existing `TSDB_KIB` inventory):
   - Compute **projected export size** (full TSDB, or sum of selected blocks + optional WAL after time filtering).
   - Compare against `MAX_GATHER_BYTES` (env) / `--max-size` (wrapper flag).
   - Default: a conservative value (e.g. `2Gi`) or “unset = warn only”; exact default decided in implementation with a note in README.
2. **Policies** via `SIZE_POLICY`:
   - `fail` (default for automation): abort before `oc cp`.
   - `warn`: log loudly and continue.
   - `truncate` (optional later): only with time-window selection — never silently drop random blocks.
3. **Error message contract** (must be human-readable **and** machine-grepable):

```text
FATAL: projected must-gather TSDB export exceeds size budget
  projected=1536MiB  budget=512MiB  policy=fail
  mode=direct  blocks_selected=12/12  window=full
  hint: narrow the window with --since/--until (or SINCE/UNTIL),
        raise MAX_GATHER_BYTES, or free space on the gather volume / --dest-dir
  see: prometheus-metadata/size-budget.txt
```

4. **Artifacts** written under `prometheus-metadata/`:
   - `size-budget.txt` — projected vs budget, policy, decision.
   - Existing inventory / `du` lines remain for forensics.

#### Implementation notes

- Prefer aborting **before** `oc cp` (cheap). Optionally re-check after copy (`du -sk` of local target) and fail if over budget (detects race with compaction).
- Align messaging with OpenShift must-gather volume limits (`--volume-percentage`): mention both gather-pod ephemeral volume and local `--dest-dir` in hints.
- Wrapper (`run-must-gather.sh`) should forward size flags into the gather environment.

---

### 2. Flags to export a given period of time

#### Operator-facing interface

| Flag / env | Meaning | Example |
| --- | --- | --- |
| `--since` / `SINCE` | Inclusive lower bound (RFC3339 or relative) | `2026-09-29T10:00:00Z`, `6h`, `2d` |
| `--until` / `UNTIL` | Inclusive upper bound (default: now) | `2026-09-29T16:00:00Z`, `now` |
| `--include-wal` / `INCLUDE_WAL` | Whether to copy WAL + `chunks_head` when window overlaps “head” | `true` (default if `until≈now`), `false` |

Relative durations parse like Prometheus (`h`, `d`, `w`). Absolute times are UTC unless offset is specified.

#### Selection algorithm

1. Run `promtool tsdb list` (already used) and parse each block’s `mint`/`maxt` (from `meta.json` or list output).
2. **Include** a compacted block if its time range **intersects** `[since, until]`.
3. If the window intersects the head (open block / WAL):
   - Prefer `MODE=snapshot` when Admin API is available (clean cut).
   - Else `MODE=direct`: copy intersecting blocks + WAL/`chunks_head` only if `--include-wal` is set; document WAL loss bound (torn tail).
4. Copy **selected paths only** into `/must-gather/prometheus-snapshot/<TS>/` preserving relative layout so playback still works.
5. Write `prometheus-metadata/time-window.json`:

```json
{
  "since": "2026-09-29T10:00:00Z",
  "until": "2026-09-29T16:00:00Z",
  "blocks_included": ["01H...", "01J..."],
  "blocks_excluded": ["01G..."],
  "include_wal": true,
  "notes": "Excluded blocks outside window to reduce gather size"
}
```

#### Playback compatibility

- Local Prometheus opens a directory of blocks; missing older blocks is fine.
- Document that queries outside `[since, until]` return empty — Grafana time range must match the window.
- If **no** block intersects the window → **fail** with a clear error (do not ship an empty “success”).

```text
FATAL: no TSDB blocks intersect the requested time window
  since=2026-01-01T00:00:00Z  until=2026-01-01T01:00:00Z
  retention_hint=see prometheus-metadata/retention.txt
  hint: widen the window or verify cluster retention still holds this period
```

---

### 3. Change the retention time (if possible)

#### What “possible” means on OpenShift

Managed Prometheus retention is owned by the **Cluster Monitoring Operator** / `Prometheus` CR (`openshift-monitoring/k8s`), typically via:

- `spec.retention` (e.g. `15d`)
- optionally `spec.retentionSize`

This toolkit must **not** silently patch production retention.

#### Proposed behavior (tiered)

| Tier | Action | When |
| --- | --- | --- |
| **A — Detect (required)** | Read effective retention from Prometheus CR args / config dump; write `prometheus-metadata/retention.txt` | Every run |
| **B — Advise (required)** | If requested window is wider than retention (or older than oldest block), fail/warn with explicit retention explanation | When `--since`/`--until` set |
| **C — Opt-in mutate (optional, gated)** | Only if `ALLOW_RETENTION_PATCH=true` **and** explicit `--set-retention=…` | Break-glass / lab clusters |

Tier C requirements if implemented:

- Pre-flight print current vs requested retention.
- Patch Prometheus CR, wait for rollout, wait until TSDB reflects new policy (best-effort; compaction/deletion is async).
- Always restore previous retention on EXIT trap unless `--keep-retention-change` is set.
- Refuse Tier C on clusters where CMO / policy forbids the patch; document the failure.

**Recommendation for v1 of this feature:** ship **A + B only**. Document Tier C as a future enhancement with strong safety gates.

---

### 4. Compression advantage on prometheus-tsdb

#### Investigation plan (must produce numbers, not opinions)

Prometheus block data is already heavily compressed (XOR/Gorilla-style chunk encoding). Additional general-purpose compression often yields **modest** gains on chunks, sometimes better on `index` / `meta.json` / WAL.

**Experiment matrix** (run on a real extracted snapshot, e.g. ~1 GiB demo-class TSDB):

| Method | Level | Metric |
| --- | --- | --- |
| Baseline raw dir | — | size, `oc cp` / tar stream time |
| `tar` only | — | size ≈ raw, time |
| `gzip` | default / -6 | ratio, compress CPU time, decompress time |
| `zstd` | 3 / 6 / 19 | ratio, compress CPU time, decompress time |
| Per-block archive vs whole-tree archive | — | parallelizability, gather complexity |
| Compress only WAL + index (leave chunks raw) | — | targeted ROI |

**Success criterion for enabling compression by default:**

- ≥ **20%** size reduction **and** end-to-end gather+download wall time not worse than **1.3×** baseline on reference hardware, **or**
- Clear win for constrained links (document as opt-in `COMPRESS=zstd` even if default stays off).

**Likely gather integration options** (choose after measurement):

1. Stream `tar | zstd` inside the gather pod into `/must-gather/prometheus-snapshot/<TS>.tar.zst` (+ small README for playback unpack).
2. Compress only after copy, before framework rsync (CPU on gather pod).
3. Leave uncompressed in-cluster; document host-side compression post-download (weakest for must-gather volume pressure).

Artifacts: `features/experiments/tsdb-compression-results.md` (or a table in this file’s “Outcomes” section once run).

---

## Architecture (data flow)

```text
                    ┌─────────────────────────────────────────┐
                    │           run-must-gather.sh            │
                    │  forwards: SINCE, UNTIL, MAX_GATHER_*,  │
                    │            SIZE_POLICY, COMPRESS, …     │
                    └───────────────────┬─────────────────────┘
                                        │
                                        ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ gather                                                                   │
│  1. Auth + pre-flight                                                    │
│  2. Inventory blocks + retention + size                                  │
│  3. Resolve time window → selected paths                                 │
│  4. Budget check → FATAL (clear message) or continue                     │
│  5. Extract (snapshot|direct) selected paths                             │
│  6. Optional compress                                                    │
│  7. Metadata: size-budget, time-window, retention, compression stats     │
└──────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                         /must-gather → operator --dest-dir
```

---

## Public interface sketch

### Wrapper

```bash
./run-must-gather.sh quay.io/<user>/prometheus-tsdb-gather:<tag> \
  --since 6h \
  --until now \
  --max-size 512Mi \
  --size-policy fail
```

### Environment (gather pod)

```bash
SINCE=6h
UNTIL=now
MAX_GATHER_BYTES=536870912
SIZE_POLICY=fail          # fail | warn
INCLUDE_WAL=true
COMPRESS=none             # none | zstd | gzip  (default after study)
```

Flags on the wrapper are the supported UX; env vars remain for debugging and image-level defaults.

---

## Alternatives considered

| Alternative | Pros | Cons | Decision |
| --- | --- | --- | --- |
| Only document “don’t gather huge TSDBs” | Zero code | Does not prevent outages | Reject as sole fix |
| Always compress, never filter | Simple | Weak ROI likely; still copies unused history | Reject without measurement |
| Delete old blocks in-place on the live pod | Shrinks source fast | Dangerous to production TSDB | Reject |
| Remote-read / HTTP export of range | Precise window | Heavy new dependency; auth; not crash-consistent file forensics | Out of scope for this toolkit |
| Rely solely on CMO `retentionSize` | Ops-standard | Does not help one-shot forensic export | Complementary only |

---

## Implementation plan

### Phase 0 — Spec & measurement

- [ ] Freeze flag names and error-message templates (this document).
- [ ] Run compression matrix on a representative snapshot; record results.
- [ ] Confirm block selection via `meta.json` mint/maxt on Prometheus 3.x layouts used here.

### Phase 1 — Size safeguard + errors

- [ ] Add budget computation and `SIZE_POLICY` gate before `oc cp`.
- [ ] Emit `size-budget.txt` + FATAL/WARN lines matching the contract above.
- [ ] Wire wrapper env forwarding; document in README Troubleshooting.

### Phase 2 — Time-window export

- [ ] Parse `SINCE`/`UNTIL`; select intersecting blocks.
- [ ] Selective copy paths; `time-window.json` metadata.
- [ ] Empty-intersection and oversize-window errors.
- [ ] Playback doc: set Grafana range to the exported window.

### Phase 3 — Retention awareness

- [ ] Always record effective retention + oldest/newest block times.
- [ ] Cross-check requested window vs retention / available data.
- [ ] Document why Tier C (live retention patch) is deferred.

### Phase 4 — Compression (data-driven)

- [x] Publish experiment results.
- [x] If ROI met: add `COMPRESS` with checksum + unpack instructions for playback.
- [x] If ROI not met: keep `COMPRESS=none` default; document opt-in and host-side tips.

---

## Outcomes (measured on this cluster, 2026-10-03)

All four capabilities implemented in gather v1.3.0 and verified end-to-end with
`oc adm must-gather --image=quay.io/midu/prometheus-tsdb-gather:v6 --dest-dir …`
against this SNO cluster (Prometheus 3.13.2, `MODE=direct`).

- **Size safeguard** — pre-flight budget gate before any copy. Default budget 2Gi,
  `SIZE_POLICY=fail`. Verified: full ~960 MiB export under 2Gi budget → `allow`;
  same export with `100Mi` budget → `FATAL: projected must-gather TSDB export
  exceeds size budget` + `decision=deny`, **nothing copied**. Artifacts:
  `prometheus-metadata/size-budget.txt` (written on allow *and* deny).
- **Time-window export** — verified `--since 16h` → 2 of 5 blocks, 962→652 MiB;
  excluded blocks never leave the pod. Empty window (30d–29d, older than the
  ~1 day of data on disk) → `FATAL: no TSDB blocks intersect the requested time
  window`, pre-copy. Artifacts: `time-window.json`, `block-inventory.tsv`.
- **Retention** — Tier A+B shipped: `retention.txt` records effective retention
  (15d from the Prometheus CR), data bounds, and window-vs-data verdict. The
  live patch Tier C remains intentionally deferred (break-glass only).
- **Compression** — `COMPRESS=zstd` default. Measured: 850 MB raw → 238 MB
  `tar.zstd` (ratio ~0.28, i.e. **~72% reduction**) in ~4 s on the gather pod.
  `SHA256SUMS` shipped; the exact unpack command is in `compression.txt`.
  Base payload image does **not** ship zstd, so the Containerfile now does
  `dnf -y install zstd`.
- **Operator UX** — the whole feature is drivable from the raw framework command
  (extra args after `--` become the container command), no wrapper required:
  `oc adm must-gather … --dest-dir … -- /usr/bin/gather --since 6h --max-size 1Gi`.
  Auth falls back to the framework's in-cluster cluster-admin SA when no Secret is
  injected. Full guide: `docs/selective-size-safe-gather.md`.
- **Bug fixes found during verification** — `--max-gb` post-copy prune loop
  compared against the wrong variable (would prune all blocks when
  `MAX_GATHER_BYTES=none`); the remote `tar` pipe treated the *expected*
  live-WAL `file changed as we read it` loss bound as a fatal error. Both
  fixed; see the git log.

Residual note (documented, not a defect): `oc adm must-gather` does not
propagate the payload's non-zero exit code, so operators check `gather.log`
for `FATAL` (both FATAL messages are stable and machine-grepable per §1.3).

---

## Testing plan

| Case | Expectation |
| --- | --- |
| Full export under budget | Success; metadata shows `policy` decision `allow` |
| Full export over budget, `fail` | Non-zero exit **before** copy; FATAL message with hints |
| Full export over budget, `warn` | Continues; WARN in `gather.log` |
| `--since 6h` with matching blocks | Only intersecting blocks present; playback queries work in window |
| Window with no blocks | FATAL empty-intersection message |
| Window older than retention | FATAL/WARN citing `retention.txt` |
| Snapshot mode + window | Uses admin snapshot when available; still filters if needed |
| Compression on/off | Bit-identical metrics after decompress + playback smoke query |
| Secrets | No kubeconfig/tokens in `/must-gather` (existing rule) |

---

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Partial block selection breaks TSDB open | Only copy complete ULID dirs; never split a block |
| WAL omission leaves gap near `until=now` | Default `INCLUDE_WAL=true` when window touches head; document loss bound |
| Retention patch disrupts production | Tier C gated / deferred; prefer detect+advise |
| Compression CPU extends gather past `--timeout` | Bound compress time; skip or fail per policy; raise `GATHER_TIMEOUT` guidance |
| Misleading “success” with empty data | Explicit empty-window failure |

---

## Success metrics

- Zero silent oversized gathers in CI/manual runs when `SIZE_POLICY=fail`.
- ≥1 documented incident-style run exporting a **subset** window with **≥50%** size reduction vs full TSDB (when history is longer than the window).
- Compression decision backed by a published ratio/time table.
- Operators can diagnose failures from **one** FATAL block without reading the full script.

---

## Open questions

1. Default `MAX_GATHER_BYTES`: fixed `2Gi`, percentage of gather volume, or warn-only until Phase 2?
2. Should time filtering apply in `MODE=snapshot` by post-filtering the snapshot directory (simpler) or by asking Prometheus for a ranged dump (not available)?
3. Is host-side playback expected to auto-detect `.tar.zst`, or do we always unpack in the gather image before rsync?
4. Do we need a dry-run mode (`--plan`) that prints selected blocks + projected size without copying?

---

## Acceptance checklist (GitHub-ready)

- [ ] Feature flagged behind documented env/CLI options with sensible defaults.
- [ ] Error messages are stable enough to scrape in CI (`FATAL: projected must-gather` / `FATAL: no TSDB blocks`).
- [ ] Metadata files describe size, window, and retention for every run.
- [ ] README Troubleshooting table updated with new failure modes.
- [ ] No secrets in output tree.
- [ ] Compression default justified by experiment results linked from this doc.
- [ ] Changelog / release note entry when implemented (e.g. gather `version` bump).

---

## References

- Repository README — Prometheus TSDB Forensics extract + playback flow.
- `gather` — pre-flight `du -sk`, `promtool tsdb list` / `analyze`, MODE=`snapshot`|`direct`.
- `run-must-gather.sh` — kubeconfig injection, `--timeout`, dest-dir download.
- [Prometheus storage / TSDB](https://prometheus.io/docs/prometheus/latest/storage/) — block layout, retention, crash consistency.
- [OpenShift must-gather](https://docs.openshift.com/container-platform/latest/support/gathering-cluster-data.html) — image contract, volume limits.
- Prometheus Admin API `POST /api/v1/admin/tsdb/snapshot` — preferred consistent full copy when enabled.

---

## Appendix: suggested issue / PR titles

- `feat: enforce must-gather TSDB size budget with actionable errors`
- `feat: add --since/--until selective TSDB export`
- `docs: record Prometheus retention in gather metadata`
- `research: measure zstd/gzip ROI on prometheus-tsdb must-gather payloads`

Use one PR per phase where possible; keep this document updated (`Status: In progress` → `Done`) as work lands.
