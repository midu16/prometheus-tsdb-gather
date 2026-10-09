# Forensic Playback

Local playback of a prometheus-tsdb-gather snapshot: starts Prometheus purely
to READ the extracted TSDB (no scraping) and wires Grafana in front of it, so
every graph in Grafana comes from data that actually existed on the SNO
prometheus.

Works with Podman (`podman compose`) and Docker.

## Directory contents

| File / dir              | Purpose |
|-------------------------|---------|
| `docker-compose.yml`    | Stack definition: `fg-prometheus` + `fg-grafana` on a private bridge network `fgnet`. |
| `prometheus.yml`        | Minimal Prometheus config, **intentionally empty `scrape_configs`** — zero network egress, no new series polluting the historical dataset. |
| `datasource.yml`        | Grafana datasource provisioning: auto-creates a default Prometheus datasource `sno-prom` (uid `sno-tsdb`) pointing at `http://prometheus:9090` (service DNS name on `fgnet`). |
| `dashboards/dashboards.yml` | Grafana dashboard provisioning: loads every `*.json` in the mounted dashboards dir into the `SNO Forensics` folder, re-scans every 10 min. |
| `dashboards/overview.json`  | "SNO TSDB Forensics - Overview" dashboard (uid `sno-forensic-overview`): Prometheus Up (block count), Series/Samples (head), Node CPU %, Node Memory %, Node Disk per mount, master-0 Network Traffic. |

## Required environment variable

`SNAPSHOT_DIR` — absolute path to the **inner** TSDB root of the snapshot,
i.e. the directory that directly contains the `block-<ULID>` dirs,
`chunks_head/` and `wal/`:

```
<snapshot>/prometheus-snapshot/<TS>/     <- SNAPSHOT_DIR points HERE
```

NOT the `prometheus-snapshot/` parent — pointing at the parent starts
Prometheus on an empty TSDB (0 series, "No datapoints yet").

For a must-gather extraction the layout is two more levels deeper:

```
must-gather.local.<cluster-id>.<ts>.<rand>/quay-io-*/prometheus-snapshot/<TS>/
```

Pick the newest snapshot automatically (bash):

```bash
MG_DIR=$(ls -dt ./must-gather.local.* | head -1)
SNAPSHOT_DIR=$(find "$MG_DIR" -type d -path '*/prometheus-snapshot/*' | sort | tail -1)
SNAPSHOT_DIR=${SNAPSHOT_DIR%/} podman compose -f playback/docker-compose.yml up -d
```

## Run

```bash
SNAPSHOT_DIR=/abs/path/to/prometheus-snapshot/<TS> \
  podman compose -f playback/docker-compose.yml up -d
```

Stop:

```bash
SNAPSHOT_DIR=/abs/path/to/prometheus-snapshot/<TS> \
  podman compose -f playback/docker-compose.yml down
```

Wait ~10-30 s after start (WAL replay). Verify data:

```bash
curl -s 'http://127.0.0.1:9091/api/v1/series?match[]=up' | head -c 300
```

## Endpoints

| What      | Where                          | Login          |
|-----------|--------------------------------|----------------|
| Prometheus UI/API | http://127.0.0.1:9091   | none           |
| Grafana   | http://127.0.0.1:3000         | admin / admin  |

- Prometheus host port defaults to **9091** because 9090 was occupied on the
  reference host. Override with `PROM_HOST_PORT=9090` when 9090 is free.
- Grafana datasource/dashboard provisioning is automatic — no UI setup.
  The overview dashboard is in the **SNO Forensics** folder.

## Host constraints (why the flags are there)

Verified on the reference host (Bazzite, SELinux Enforcing, 2026-09-29):

1. **SELinux**: files under `/var/apps` carry the `unlabeled_t` label, which
   denies container reads → all mounts use `:Z` private relabel. Plain `:ro`
   mounts fail with EPERM. Hosts without SELinux ignore the flag.
2. **Ownership**: the extracted snapshot is owned by the host user; the
   prometheus image user (`nobody`) cannot create `queries.active`/`lock` in
   the mounted dir → the prometheus container runs `user: "0"`.
   Local-only, bound to 127.0.0.1 — acceptable for forensics.

## Behavior notes

- On startup Prometheus re-opens the blocks and **replays the WAL**, which is
  what makes a direct copy of a live TSDB safe to query.
- `--storage.tsdb.retention.time=0d`: nothing is deleted during analysis.
- `--web.enable-admin-api` is on for interactive TSDB control; the web is
  bound to 127.0.0.1 only.
- Because there are no scrape jobs, the head stays near-empty; the data
  lives in the loaded blocks. Check queries via Grafana, the Prometheus
  Explore tab, or the `/api/v1/series` / `/api/v1/query` endpoints.
