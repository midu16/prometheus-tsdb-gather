# =============================================================================
# Makefile -- forensic playback stack (Prometheus + Grafana + Perses)
#
# Drives docker-compose.yml via podman-compose. SNAPSHOT_DIR is auto-detected
# from the newest must-gather drop in ../../demo-run unless you override it:
#
#   make up SNAPSHOT_DIR=/abs/path/to/prometheus-snapshot/<TS>
#
# The auto-detected value is the <TS> directory DIRECTLY under
# <dest-dir>/quay-io-*/prometheus-snapshot/ (the plain TSDB root with the
# block-<ULID> dirs). Anything deeper (blocks, chunks) is wrong.
# =============================================================================

SHELL        := /bin/bash
COMPOSE      ?= podman-compose
COMPOSE_FILE ?= docker-compose.yml
PROM_HOST_PORT ?= 9091

# Effective data window of the snapshot (from must-gather prometheus-metadata/time-window.json).
# Used only by the `verify` target's sample query - override per snapshot.
WINDOW_START ?= 2026-10-11T12:00:00Z
WINDOW_END   ?= 2026-10-12T12:00:00Z

DEMO_RUN ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../demo-run)
SNAP_PARENT_TMP := $(strip $(shell test -d "$(DEMO_RUN)" && find "$(DEMO_RUN)" -type d -name prometheus-snapshot 2>/dev/null | sort))
SNAP_PARENT     := $(lastword $(SNAP_PARENT_TMP))
SNAP_LATEST     := $(shell test -n "$(SNAP_PARENT)" && ls -td "$(SNAP_PARENT)"/*/ 2>/dev/null | head -1)

# SNAPSHOT_DIR: command-line override wins; otherwise the newest <TS> dir.
# Value may carry a trailing slash - normalized below for the :Z mount.
SNAPSHOT_DIR ?= $(SNAP_LATEST)
export SNAPSHOT_DIR := $(SNAPSHOT_DIR:%/=%)

.PHONY: help up down restart ps logs verify clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

pre: ## (internal) validate SNAPSHOT_DIR
	@test -n "$(SNAPSHOT_DIR)" || { echo "ERROR: SNAPSHOT_DIR is empty and auto-detect failed (no prometheus-snapshot found under $(DEMO_RUN))"; exit 1; }
	@test -d "$(SNAPSHOT_DIR)" || { echo "ERROR: SNAPSHOT_DIR does not exist: $(SNAPSHOT_DIR)"; exit 1; }
	@test -n "$$(ls "$(SNAPSHOT_DIR)" | grep -c .)" || { echo "ERROR: SNAPSHOT_DIR is empty (point at the <TS> dir containing the block-<ULID> dirs)"; exit 1; }
	@echo "SNAPSHOT_DIR = $(SNAPSHOT_DIR)"

up: pre ## Create + start the stack (fg-prometheus, fg-grafana, fg-perses)
	PROM_HOST_PORT="$(PROM_HOST_PORT)" $(COMPOSE) -f $(COMPOSE_FILE) up -d

down: pre ## Teardown the stack
	$(COMPOSE) -f $(COMPOSE_FILE) down

restart: pre ## Restart one service: make restart SERVICE=prometheus|grafana|perses
	@test -n "$(SERVICE)" || { echo "usage: make restart SERVICE=prometheus|grafana|perses"; exit 1; }
	$(COMPOSE) -f $(COMPOSE_FILE) restart $(SERVICE)

ps: ## Show stack containers
	@podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | { read -r h; echo "$$h"; grep -E '^fg-' || echo "  (no fg- containers running)"; }

logs: ## Tail logs: make logs SERVICE=prometheus (default) | grafana | perses
	@test -n "$(SERVICE)" || { echo "usage: make logs SERVICE=prometheus|grafana|perses"; exit 1; }
	podman logs -f --tail 100 fg-$(SERVICE)

verify: ## Health-check all services + query the block window
	@echo "== containers =="
	@podman ps --format '{{.Names}}: {{.Status}}' | grep '^fg-'
	@echo
	@echo "== prometheus (127.0.0.1:$(PROM_HOST_PORT)) =="
	@echo "  ready:        $$(curl -s 'http://127.0.0.1:$(PROM_HOST_PORT)/-/ready')"
	@curl -s 'http://127.0.0.1:$(PROM_HOST_PORT)/metrics' | grep -E '^prometheus_tsdb_blocks_loaded ' | sed 's/^/  /'
	@echo "  node_memory in window:"
	@curl -sG 'http://127.0.0.1:$(PROM_HOST_PORT)/api/v1/query_range' \
		--data-urlencode 'query=avg by (instance) (node_memory_MemAvailable_bytes)' \
		--data-urlencode "start=$(WINDOW_START)" \
		--data-urlencode "end=$(WINDOW_END)" \
		--data-urlencode 'step=30m' \
		| python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; [print("   ", x["metric"], "points:", len(x["values"]), "avg GiB:", round(sum(float(v) for _, v in x["values"])/len(x["values"])/1e9, 2)) for x in r] or print("    (no data in window)")'
	@echo
	@echo "== grafana (127.0.0.1:3000, admin/admin) =="
	@curl -s 'http://127.0.0.1:3000/api/health' | sed 's/^/  /'
	@echo
	@echo "== perses (127.0.0.1:8080) =="
	@curl -s 'http://127.0.0.1:8080/api/v1/health' | sed 's/^/  /'
	@curl -s 'http://127.0.0.1:8080/api/v1/globaldatasources' | python3 -c 'import json,sys; [print("  global datasource:", d["metadata"]["name"]) for d in json.load(sys.stdin)]'

clean: down ## Teardown + remove container remnants if any
	@echo "done (use `podman volume prune` if you also want to drop anonymous volumes)"




