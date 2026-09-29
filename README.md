# Prometheus TSDB Forensics

Two-stage toolkit:

1. **Extract** — a custom OpenShift `must-gather` image triggers a crash-consistent
   TSDB snapshot on `prometheus-k8s-0` via the Prometheus Admin API and ships it
   back to this machine.
2. **Play back** — a Podman/Docker compose stack opens the snapshot in local
   Prometheus + Grafana, with zero scraping and no manual datasource setup.

---

## PART 1 — Extract

### 1.1 Inject the operator kubeconfig + run the must-gather

`oc adm must-gather` generates the gather pod spec itself and has **no flag
for extra volumes or env** — so the kubeconfig travels as a **Secret** that
we create on the outside, and the gather container fetches it from inside
(the framework pod runs with a cluster-admin-bound service account, so it
can read it). `gather-image/run-must-gather.sh` performs the whole flow;
here are the exact commands (from the working directory, dest dir = this
directory, so the extracted tree lands here as `./must-gather/`):

```bash
# 0) point our own 'oc' at the cluster
export KUBECONFIG=/path/to/auth/kubeconfig

# 1) prepare the kubeconfig injection (namespace + Secret + RBAC)
#    Secret type Opaque, single key 'kubeconfig' -> data key 'kubeconfig'
oc get namespace must-gather >/dev/null 2>&1 || oc create namespace must-gather
oc create secret generic must-gather/mg-kubeconfig \
    --from-file=/path/to/workdir/auth/kubeconfig
# CRITICAL (verified 2026-09-29): the framework only cluster-admins pods in
# namespaces IT creates. In a pre-existing --run-namespace the gather pod runs
# as that namespace's 'default' SA with NO permissions -> the in-pod
# 'oc get secret' fails Forbidden. Grant it read on the one secret:
oc create role        must-gather/mg-kubeconfig-reader --verb=get --resource=secrets --overwrite
oc create rolebinding must-gather/mg-kubeconfig-reader --serviceaccount=must-gather:default --role=must-gather/mg-kubeconfig-reader --overwrite

# 2) RUN (the wrapper wraps steps 1+3+4; blocks until the download completes)
./gather-image/run-must-gather.sh quay.io/<your-user>/prometheus-tsdb-gather:v6
#    ... or, fully manual, the single framework call the wrapper makes
#    (note 'set -o pipefail': without it a Forbidden on the secret would
#     silently write an EMPTY kubeconfig and the run would continue broken):
# oc adm must-gather \
#     --image quay.io/<your-user>/prometheus-tsdb-gather:v6 \
#     --source-dir /must-gather \
#     --timeout 60m \
#     --run-namespace must-gather \
#     --dest-dir /var/apps/sno.frntdeu1.pop.starlinkisp.net/promethes-gather \
#     -- bash -c 'set -e -o pipefail; mkdir -p /etc/must-gather-kubeconfig; \
#                 oc get secret mg-kubeconfig -n must-gather -o jsonpath={.data.kubeconfig} | base64 -d > /etc/must-gather-kubeconfig/kubeconfig; \
#                 chmod 600 /etc/must-gather-kubeconfig/kubeconfig; \
#                 export KUBECONFIG=/etc/must-gather-kubeconfig/kubeconfig; \
#                 exec /usr/bin/gather'

# 3) CLEANUP (the wrapper already deleted the Secret on exit — verify +
#    optionally delete the namespace; it auto-deletes ~2min after the run)
oc get secret mg-kubeconfig -n must-gather 2>&1 | grep -i 'not found'   # expect: NotFound
oc delete namespace must-gather --ignore-not-found --wait=false
```

**How the kubeconfig gets into the pod** (command mode, the default): the
framework executes everything after `--` as the container command, so the
bootstrap above runs *before* `/usr/bin/gather`. It decodes
`must-gather/mg-kubeconfig` into `/etc/must-gather-kubeconfig/kubeconfig`,
exports `KUBECONFIG`, and `exec`s gather — which re-exports the same path
for every `oc`/`curl` call. No timing race: the Secret (+ its Role/RoleBinding)
exist before the pod starts. Two traps are built in and both were hit in
production (2026-09-29): the in-pod `oc` uses the pod SA (the `default` SA in
a pre-existing namespace — hence the explicit Role/RoleBinding), and
`set -o pipefail` makes a `Forbidden` abort the bootstrap instead of
silently writing an empty kubeconfig.
(`INJECT=patch ./run-must-gather.sh …` instead JSON-patches the Job to
**mount** the Secret as a volume — the literal volumeMount variant — but a
patch cannot restart a terminated pod, so that mode is best-effort; see the
wrapper header.)

> **Client-version notes** (verified 2026-09-29 against `oc 5.0.0-rc.2` on
> this host): the namespace flag is `--run-namespace` (oc 4.x:
> `--namespace`); this client has **no** `--log-file` flag → the wrapper
> redirects the client log to `./must-gather.log` itself; there is no
> `--image-pull-policy` flag → for the offline Option B (image imported via
> `ctr i import` on `master-0`) the default pull policy succeeds because the
> image is already local on the only node.

What happens under the hood (framework behavior):

| Step | Where | What |
|------|-------|------|
| 1 | control plane | `oc adm must-gather --run-namespace must-gather` runs our image in a pod named `must-gather-<suffix>`; the pod uses that namespace's `default` SA (our Role/RoleBinding gives it read on the kubeconfig Secret); command = kubeconfig bootstrap → `/usr/bin/gather` |
| 2 | inside gather pod | bootstrap materializes the kubeconfig → `export KUBECONFIG` → pre-flight → snapshot probe → extraction → metadata |
| 3 | control plane | framework copy sidecar **rsyncs `/must-gather`** out, then the CLI downloads it to `--dest-dir` |
| 4 | this box | `./must-gather.local.<cluster-id>.<ts>.<rand>/quay-io-*/` appears in the working directory |

The gather script itself (v6, what actually runs on this cluster):

- **auth**: resolves `/etc/must-gather-kubeconfig/kubeconfig`, validates,
  `export KUBECONFIG=…` for all calls (env override `MUST_GATHER_KUBECONFIG`)
- **pre-flight**: `oc whoami` (payload carries an **oc 4.15** client — no
  `--timeout` flag, verified), node `master-0` Ready + roles,
  `prometheus-k8s-0` Running/Ready (180s retry for restarts), web-port probe
  (9090/9091 from inside the pod), TSDB dir inventory
- **snapshot probe**: `POST /api/v1/admin/tsdb/snapshot`. On this cluster
  Prometheus **3.13.2** answers `500 "admin APIs disabled"` (the OCP operator
  does not enable `prometheus-admin-api`) → the script automatically falls
  back. To make the admin-API path work: `oc patch prometheus k8s -n
  openshift-monitoring --type=merge -p '{"spec":{"enableFeatures":["delayed-compaction","use-uncached-io","prometheus-admin-api"]}}'`
  (pod restarts once; next run takes the snapshot path)
- **extract** (`MODE=direct` fallback, verified): `oc cp prometheus-k8s-0:/prometheus
  /must-gather/prometheus-snapshot/<UTC-ts>` — a TSDB is crash-consistent, the
  local prometheus replays the WAL on open (worst case: torn tail of the newest
  WAL segment). `MODE=snapshot` instead copies `/prometheus/snapshots/<ts>`
- **metadata**: node/pod JSON, `pod describe`, log tail, rendered config (tokens
  redacted), in-cluster `promtool tsdb list` + `analyze` of the newest block
  (promtool 3.x has **no** `tsdb verify`), structural check of the local copy
- **cleanup**: `rm -rf /prometheus/snapshots/<ts>` in snapshot mode (also the
  `EXIT` trap); **direct mode writes nothing to the target pod**

### 1.2 Verify the extraction

```bash
cd /path/to/promethes-gather

MG=$(ls -dt must-gather.local.* | head -1)                    # newest run
P="$MG"/quay-io-*-prometheus-tsdb-gather-*                    # payload dir

ls "$P"
#   version            # "prometheus-tsdb-must-gather" / "1.1.0"
#   gather.log         # full in-cluster script log
#   whoami.txt
#   prometheus-snapshot/<UTC-TS>/   # the TSDB: <ULID> block dirs + wal + chunks_head
#   prometheus-metadata/            # verification + context files

grep 'DONE - mode=' "$P/gather.log"                            # expect: DONE - mode=direct...
cat "$P/prometheus-metadata/tsdb-verify.txt"                   # in-cluster promtool tsdb list
cat "$P/prometheus-metadata/tsdb-local-struct.txt"             # local copy structure check
du -sh "$P/prometheus-snapshot"
```

---

## Troubleshooting (all rows actually hit on this cluster, 2026-09-29)

| Symptom | Cause / fix |
|---------|-------------|
| gather FATAL `oc whoami failed - gather pod has no cluster access` but whoami.txt says `unknown flag: --timeout` | payload's oc 4.15 client rejects `--timeout`. Fixed in v6 (bare `oc whoami`). Rebuild + **new tag** and re-run |
| Bootstrap log: `secrets "mg-kubeconfig" is forbidden: User "system:serviceaccount:must-gather:default"` | framework does NOT cluster-admin pods in a pre-existing `--run-namespace` → create the `mg-kubeconfig-reader` Role/RoleBinding (README §1.2 step 1) |
| Bootstrap succeeds but `KUBECONFIG=…(user: ?)` and gather runs broken | `oc get secret` failed but `base64 -d` wrote an empty file (silent). v6 bootstrap has `set -o pipefail` — aborts instead. Check the Role/RoleBinding from the row above |
| `oc adm must-gather` runs an OLD script (e.g. pre-fix whoami bug) | node CRI-O cached the tag. **Push a new tag** (`v6`, `v7`, …) per immutable payload |
| gather log: `Admin API snapshot unavailable (… "admin APIs disabled")` | EXPECTED here: prometheus 3.13.2, OCP operator doesn't enable `prometheus-admin-api`. The script falls back to `MODE=direct` automatically — same mounted TSDB end result. (To force the admin-API path: patch `spec.enableFeatures`, see §1.2) |
| `ErrImagePull … reading blob …: EOF` | quay CDN hiccup mid-pull. Retry the push, verify with `podman pull <ref>` from the operator box, re-run |
| Prometheus container exit 2, `panic: Unable to create mmap-ed active query log` | `queries.active` not writable: snapshot dir owned by host user, prom image runs as `nobody` → `user: "0"` in compose (done) |
| `open /prometheus/…: permission denied` for mounts on this host | SELinux `unlabeled_t` source files → `:Z` on the mounts (done in compose) |
| compose prometheus starts but serves 0 series; dir has only `wal/`+`chunks_head` | `SNAPSHOT_DIR` was RELATIVE → podman rooted it at the compose file's dir and auto-created an empty tree there. Use an ABSOLUTE `SNAPSHOT_DIR`; delete the bogus `playback/must-gather.local.*/` tree |
| `podman-compose up -d` hangs | this host: old docker-compose-v1 delegation / slow pull. Pre-pull both images, use standalone `podman-compose`, `timeout 240 … up -d` |
| host `curl 127.0.0.1:9091` times out but container is up | pasta port-forward flakiness (Bazzite). Query in-container: `podman exec fg-prometheus wget -qO- 'http://127.0.0.1:9090/…'` |
| Grafana queries return 0 points | instant query at "now" on historical data. Use `start`/`end` inside the block window (see `prometheus-metadata/tsdb-verify.txt`) |

## Notes & caveats

- **SNO single point of failure**: the Prometheus PVC is local disk on
  `master-0`. The `MODE=direct` fallback is exactly what makes this toolkit
  robust here — it reads the crash-consistent TSDB in place and needs the
  running prom process only as a file server (`oc cp`), so it works even in a
  degraded instance. If the node were NotReady the pre-flight would fail; for
  a salvage run point `PROM_POD=<actual-name>` and relax checks 0b/0c.
- **WAL loss bound (direct mode)**: worst case you lose the torn tail of the
  newest in-flight WAL segment (a few minutes). Everything already compacted
  into a block is lossless. For a zero-loss guarantee enable the admin API
  (§1.2) and take a real snapshot — the playbook is identical.
- **Version skew**: payload base is `ose-must-gather:latest` (oc client
  4.15-series). Cluster is Kubernetes v1.36 / OCP 5.0.0-rc.2. The in-pod oc
  being older than the API server is fine for the verbs used (get/exec/cp) —
  but is the reason `oc whoami --timeout` broke it (§Troubleshooting). The
  playback reader `prom/prometheus:v3.4.0` is older than the OCP prom
  (3.13.2); TSDB format is backward compatible within a major (3.x reads the
  3.13 blocks — verified 2,707 distinct metrics from the extracted TSDB).
- **Secrets**: the gather script redacts tokens in the rendered
  `prometheus-crd.yaml`. The operator kubeconfig is injected only into the
  transient gather pod and is NEVER written to the output tree. The
  `must-gather/mg-kubeconfig` Secret still holds the full cluster-admin
  kubeconfig — the wrapper deletes it on exit (trap), and you should verify
  (`oc get secret mg-kubeconfig -n must-gather`) and delete the namespace.
  Review `must-gather.local.*/` before sharing externally.
- **Local host specifics (Bazzite / SELinux-enforcing)**: the compose file
  needs `:Z` mounts + `user:"0"` here (§2.2). On a permissive/non-SELinux box
  those are harmless no-ops and `:ro`/the image user would also work.
