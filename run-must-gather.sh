#!/usr/bin/bash
# =============================================================================
# run-must-gather.sh -- run the custom TSDB must-gather WITH kubeconfig injection
#
# WHY A WRAPPER, AND WHY A SECRET
# ------------------------------
# 'oc adm must-gather' generates the gather pod spec itself and exposes NO
# flag for extra volumes or env. The kubeconfig therefore travels as a
# Secret that the operator creates on the outside, and the gather container
# fetches it from inside the cluster (the framework runs the pod as a
# cluster-admin-bound service account, so it can read the secret).
#
# INJECTION MECHANISM (default, INJECT=command) -- deterministic, no race:
#   1. oc create namespace must-gather                      (known, ours)
#   2. oc create secret generic must-gather/mg-kubeconfig \
#          --from-file=kubeconfig=<operator kubeconfig>     (type Opaque,
#          single key 'kubeconfig' -> data.kubeconfig base64)
#   3. oc adm must-gather --image <custom> \
#          --run-namespace must-gather \
#          -- bash -c <BOOTSTRAP>                            where BOOTSTRAP is:
#        oc get secret mg-kubeconfig -n must-gather \
#            -o jsonpath={.data.kubeconfig} | base64 -d \
#            > /etc/must-gather-kubeconfig/kubeconfig
#        chmod 600 /etc/must-gather-kubeconfig/kubeconfig
#        export KUBECONFIG=/etc/must-gather-kubeconfig/kubeconfig
#        exec /usr/bin/gather
#      Because the framework passes the post-'--' args as the container
#      command, the bootstrap runs FIRST inside the pod - before our gather
#      script - and hands it the operator kubeconfig at the exact path the
#      script exports (gather: KUBECONFIG_MOUNT_PATH). Zero timing race:
#      the secret already exists before the pod even starts.
#
# INJECTION MECHANISM (INJECT=patch) -- literal volumeMOUNT, for completeness:
#   pre-create the Secret (step 2), run must-gather normally, then JSON-patch
#   the Job's container with
#       volumes:      + {name: kubeconfig, secret: {secretName: mg-kubeconfig}}
#       volumeMounts: + {name: kubeconfig, mountPath: /etc/must-gather-kubeconfig}
#   This is the true "mount it" variant, BUT a patch only affects a pod that
#   has not terminated, so it is timing-dependent on big/fast nodes; the
#   payload's SA-token fallback covers the miss. Use only if you specifically
#   want the kubeconfig to appear as a mounted file in the pod spec.
#
# THE must-gather DIRECTORY STRUCTURE (what the CLI downloads to --dest-dir):
#   --dest-dir/must-gather/
#     ├── version                       # payload id + version (2 lines)
#     ├── gather.log                    # in-cluster script log
#     ├── whoami.txt / oc-cp.stderr
#     ├── prometheus-snapshot/<TS>/     # the TSDB root: block-*/ + index + meta.json
#     └── prometheus-metadata/          # JSON + verification files (README §1.3)
#
# THE OPERATOR KUBECONFIG IS NEVER COPIED INTO /must-gather (must-gather rule:
# no secrets in the output tree); only the bootstrap file on the pod's
# ephemeral filesystem references it, and the pod is deleted after the run.
#
# USAGE
# -----
#   export KUBECONFIG=/var/apps/sno.frntdeu1.pop.starlinkisp.net/workdir/auth/kubeconfig
#   cd /var/apps/sno.frntdeu1.pop.starlinkisp.net/promethes-gather
#   ./gather-image/run-must-gather.sh quay.io/<you>/prometheus-tsdb-gather:v1
#
#   Offline image (MUST-GATHER-GUIDE.md Option B):
#     IMAGE=localhost/prometheus-tsdb-gather:v1 \
#     (with the tar imported via 'sudo ctr i import' on master-0)
#
# CLIENT-VERSION NOTE (verified 2026-09-29 against oc 5.0.0-rc.2):
#   namespace flag: --run-namespace (oc 5.x) vs --namespace (oc 4.x).
#   There is NO --log-file flag in oc 5.x: this script captures the client
#   log into ${DEST_DIR}/must-gather.log via shell redirection instead.
#   --image-pull-policy does not exist in this client (default: pull); for
#   Option B the node's CRI-O must already hold the localhost: image.
# =============================================================================
set -uo pipefail

# --- configuration (override via env) ----------------------------------------
KUBECONFIG_FILE="${KUBECONFIG_FILE:-/var/apps/sno.frntdeu1.pop.starlinkisp.net/workdir/auth/kubeconfig}"
DEST_DIR="${DEST_DIR:-/var/apps/sno.frntdeu1.pop.starlinkisp.net/promethes-gather}"
NAMESPACE="${NAMESPACE:-must-gather}"
SECRET_NAME="${SECRET_NAME:-mg-kubeconfig}"
IMAGE="${1:-${IMAGE:-}}"
INJECT="${INJECT:-command}"            # command (default) | patch
MOUNT_PATH="/etc/must-gather-kubeconfig"   # MUST match gather's KUBECONFIG_MOUNT_PATH
GATHER_TIMEOUT="${GATHER_TIMEOUT:-60m}"    # snapshot + oc cp of a large TSDB
NS_GRACE_SECONDS="${NS_GRACE_SECONDS:-120}"   # keep NS after run: sidecar may still rsync
# safeguard/env pass-through (gather v1.3.0 + legacy v1.2.0): the must-gather
# framework accepts NO extra args for the payload, and the bootstrap is the
# only thing in our hands inside the pod - so these travel as env (the
# bootstrap exports them right before 'exec /usr/bin/gather').
#   v1.3.0 (features/safeguard-size-selective-export.md):
#     SINCE / UNTIL          time window ('6h', '2d', RFC3339, 'now')
#     MAX_GATHER_BYTES       budget: 512Mi / 2Gi / none  (default 2Gi)
#     SIZE_POLICY            fail (default) | warn
#     INCLUDE_WAL            true | false | auto (default auto)
#     COMPRESS               none | zstd (default) | gzip
#   v1.2.0 legacy:
#     GATHER_TSDB_AT takes anything GNU date parses; GATHER_TSDB_MAX_GB caps
#     the exported copy in GiB (default 5).
GATHER_TSDB_AT="${GATHER_TSDB_AT:-}"
GATHER_TSDB_MAX_GB="${GATHER_TSDB_MAX_GB:-}"
SINCE="${SINCE:-}"
UNTIL="${UNTIL:-}"
MAX_GATHER_BYTES="${MAX_GATHER_BYTES:-}"
SIZE_POLICY="${SIZE_POLICY:-}"
INCLUDE_WAL="${INCLUDE_WAL:-}"
COMPRESS="${COMPRESS:-}"

# --- prechecks ----------------------------------------------------------------
[[ -n "${IMAGE}" ]] \
    || { echo "usage: $0 <image-ref>   (or IMAGE=<ref> $0)" >&2; exit 2; }
[[ -f "${KUBECONFIG_FILE}" ]] \
    || { echo "ERROR: kubeconfig not found: ${KUBECONFIG_FILE}" >&2; exit 2; }
[[ "${INJECT}" == "command" || "${INJECT}" == "patch" ]] \
    || { echo "ERROR: INJECT must be 'command' or 'patch'" >&2; exit 2; }
# sanity: operator kubeconfig must already authenticate (client-side check).
# NOTE: no --timeout — 'oc whoami' rejects it on both the host 5.x client
# and the payload's 4.15 client (verified: 'unknown flag: --timeout').
oc whoami --kubeconfig "${KUBECONFIG_FILE}" >/dev/null 2>&1 \
    || { echo "ERROR: operator kubeconfig cannot authenticate (oc whoami failed)" >&2; exit 2; }

# client-version feature probe: oc 5.x renamed --namespace -> --run-namespace
if oc adm must-gather --help 2>&1 | grep -q -- '--run-namespace='; then
    NS_FLAG="--run-namespace"
else
    NS_FLAG="--namespace"
fi
echo ">> client namespace flag: ${NS_FLAG}"

# --- cleanup-on-exit: the secret (cluster-admin creds) NEVER outlives us ------
cleanup() {
    echo ">> deleting secret '${NAMESPACE}/${SECRET_NAME}'"
    oc delete secret -n "${NAMESPACE}" "${SECRET_NAME}" --ignore-not-found >/dev/null 2>&1 || true
    if [[ "${1:-keep}" == "keep" ]]; then
        echo ">> keeping namespace '${NAMESPACE}' for ${NS_GRACE_SECONDS}s (copy sidecar may still stream), then deleting"
        (
            sleep "${NS_GRACE_SECONDS}"
            oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false --timeout=600s >/dev/null 2>&1 || true
        ) &
        disown
    fi
}
trap 'cleanup keep' EXIT
trap 'cleanup drop; exit 130' INT TERM

# --------------------------------------------------------------- 1 + 2: secret
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"
oc delete secret -n "${NAMESPACE}" "${SECRET_NAME}" --ignore-not-found >/dev/null 2>&1 || true
# Secret type Opaque; key 'kubeconfig' -> pod can jsonpath {\.data.kubeconfig}
oc create secret generic -n "${NAMESPACE}" "${SECRET_NAME}" \
    --from-file=kubeconfig="${KUBECONFIG_FILE}" >/dev/null
echo ">> secret ${NAMESPACE}/${SECRET_NAME} created (operator kubeconfig, key: kubeconfig)"

# ------------------------------------------------------- 2b: RBAC for the pod
# VERIFIED 2026-09-29: the framework grants its cluster-admin rolebinding only
# in namespaces IT CREATES. With --run-namespace <existing>, the gather pod
# runs as that namespace's default SA and has NO permissions at all (the
# bootstrap 'oc get secret' came back Forbidden). So bind the default SA to
# read the kubeconfig secret (and only that verb surface - least privilege):
SA_NAME="default"   # observed in-cluster as system:serviceaccount:<ns>:default
oc delete rolebinding -n "${NAMESPACE}" mg-kubeconfig-reader --ignore-not-found >/dev/null 2>&1 || true
oc delete role        -n "${NAMESPACE}" mg-kubeconfig-reader --ignore-not-found >/dev/null 2>&1 || true
oc create role -n "${NAMESPACE}" mg-kubeconfig-reader \
    --verb='get' --resource='secrets' >/dev/null
oc create rolebinding -n "${NAMESPACE}" mg-kubeconfig-reader \
    --serviceaccount="${NAMESPACE}:${SA_NAME}" --role=mg-kubeconfig-reader >/dev/null
echo ">> RBAC: ${NAMESPACE}/${SA_NAME} SA may now read the ${SECRET_NAME} secret"

# ------------------------------------------------------ 3: build the run args
declare -a MG_ARGS=(
    adm must-gather
    --image "${IMAGE}"
    --source-dir /must-gather           # framework rsync source dir (default; explicit)
    --timeout "${GATHER_TIMEOUT}"       # gather phase budget (copy phase not bounded)
)
# run in OUR namespace (secret lives there; pod gets a cluster-admin-bound SA)
MG_ARGS+=( "${NS_FLAG}" "${NAMESPACE}" )

if [[ "${INJECT}" == "command" ]]; then
    # BOOTSTRAP: deterministic kubeconfig delivery (see header). Runs as the
    # container command, i.e. BEFORE /usr/bin/gather. 'set -o pipefail' makes
    # a Forbidden/NotFound on the secret fail the whole pipeline (otherwise
    # 'base64 -d' would happily write an EMPTY file and the script would
    # continue with silent broken auth - exactly what the 2026-09-29 run hit).
    # v1.3.0 env exported too; UNSET wrapper vars stay UNSET in the pod so
    # gather's own defaults (2Gi, fail, auto, zstd, until=now) apply:
    BOOTSTRAP="set -e -o pipefail; mkdir -p ${MOUNT_PATH}; oc get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath={.data.kubeconfig} | base64 -d > ${MOUNT_PATH}/kubeconfig; chmod 600 ${MOUNT_PATH}/kubeconfig; export KUBECONFIG=${MOUNT_PATH}/kubeconfig"
    [[ -n "${GATHER_TSDB_AT}" ]]     && BOOTSTRAP+="; export GATHER_TSDB_AT='${GATHER_TSDB_AT}'"
    [[ -n "${GATHER_TSDB_MAX_GB}" ]] && BOOTSTRAP+="; export GATHER_TSDB_MAX_GB='${GATHER_TSDB_MAX_GB}'"
    [[ -n "${SINCE}" ]]              && BOOTSTRAP+="; export SINCE='${SINCE}'"
    [[ -n "${UNTIL}" ]]              && BOOTSTRAP+="; export UNTIL='${UNTIL}'"
    [[ -n "${MAX_GATHER_BYTES}" ]]   && BOOTSTRAP+="; export MAX_GATHER_BYTES='${MAX_GATHER_BYTES}'"
    [[ -n "${SIZE_POLICY}" ]]        && BOOTSTRAP+="; export SIZE_POLICY='${SIZE_POLICY}'"
    [[ -n "${INCLUDE_WAL}" ]]        && BOOTSTRAP+="; export INCLUDE_WAL='${INCLUDE_WAL}'"
    [[ -n "${COMPRESS}" ]]           && BOOTSTRAP+="; export COMPRESS='${COMPRESS}'"
    BOOTSTRAP+="; echo \"[bootstrap] KUBECONFIG=${MOUNT_PATH}/kubeconfig (user: $(oc whoami 2>/dev/null || echo ?)) since='${SINCE}' until='${UNTIL}' max='${MAX_GATHER_BYTES}' policy='${SIZE_POLICY}' wal='${INCLUDE_WAL}' compress='${COMPRESS}' at='${GATHER_TSDB_AT}' max_gi='${GATHER_TSDB_MAX_GB}'\"; exec /usr/bin/gather"
    MG_ARGS+=( -- "${BOOTSTRAP}" )
    echo ">> injection mode: command (bootstrap fetches secret into ${MOUNT_PATH}/kubeconfig before gather starts)"
else
    # patch mode: no container command override; gather runs with the
    # framework SA token and the Job patch (step 4) adds the mounted secret.
    echo ">> injection mode: patch (Job is patched to MOUNT the secret volume; timing-dependent)"
fi

# ------------------------------------------------------------- 4: the run (blocks)
echo ">> running: oc ${MG_ARGS[0]} ${MG_ARGS[1]} --image ${IMAGE} ${NS_FLAG} ${NAMESPACE} ... --dest-dir ${DEST_DIR}"
echo ">> client log -> ${DEST_DIR}/must-gather.log"
mg_rc=0
oc "${MG_ARGS[@]}" \
    --dest-dir "${DEST_DIR}" \
    > "${DEST_DIR}/must-gather.log" 2>&1 \
    || mg_rc=$?

# ----------------------------------------------- 5 (patch mode only): patch Job
PATCHED=0
if [[ "${INJECT}" == "patch" ]]; then
    MG_JOB="$(oc get jobs -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1}' | grep -E '^mg-' | head -1)"
    if [[ -n "${MG_JOB}" ]]; then
        oc patch job -n "${NAMESPACE}" "${MG_JOB}" --type=json -c '[
            {"op":"add","path":"/spec/template/spec/containers/0/volumes",
             "value":{"name":"kubeconfig","secret":{"secretName":"'"${SECRET_NAME}"'"}}},
            {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts",
             "value":{"name":"kubeconfig","mountPath":"'"${MOUNT_PATH}"'","readOnly":true}}
        ]' >/dev/null && PATCHED=1 \
            && echo ">> patched Job ${NAMESPACE}/${MG_JOB}: secret volume mounted at ${MOUNT_PATH}" \
            || echo ">> WARN: Job ${MG_JOB} not patchable (already terminated?); rely on SA-token fallback"
        oc get pod -n "${NAMESPACE}" -l job-name="${MG_JOB}" --no-headers \
            -o custom-columns=POD:metadata.name,PHASE:status.phase 2>/dev/null || true
    else
        echo ">> WARN: no mg-* Job found in ${NAMESPACE}; nothing to patch"
    fi
fi

# ------------------------------------------------------------ summary + exit
# 'oc adm must-gather' (this 5.x client) writes <dest-dir>/must-gather.local.<cluster-id>.<ts>.<rand>/,
# NOT a flat 'must-gather/' dir. Find the freshest one for the summary.
MG_OUT="$(ls -dt "${DEST_DIR}"/must-gather.local.* 2>/dev/null | head -1)"
echo
echo "=== oc adm must-gather exit: ${mg_rc}  $( [[ ${mg_rc} -eq 0 ]] && echo '(success)' || echo '(FAILED - check must-gather.log)' ) ==="
[[ "${INJECT}" == "patch" ]] && echo "=== kubeconfig job patched: ${PATCHED} ==="
PAYLOAD_DIR="$(find "${MG_OUT}" -maxdepth 1 -type d -name 'quay-io-*prometheus-tsdb-gather*' 2>/dev/null | head -1)"
if [[ -n "${MG_OUT}" ]]; then
    echo "=== output dir:    ${MG_OUT} ==="
    [[ -n "${PAYLOAD_DIR}" ]] && echo "=== gather log last line: $(tail -1 "${PAYLOAD_DIR}/gather.log" 2>/dev/null) ===" \
        || echo "!! no payload subdir - gather pod likely never pulled the image (see ${MG_OUT}/must-gather.logs)"
    SNAP_GLOB="${PAYLOAD_DIR}"/prometheus-snapshot/*
    if compgen -G "${SNAP_GLOB}" >/dev/null; then
        echo "=== extracted data:"
        du -sh ${SNAP_GLOB} 2>/dev/null || true
    else
        echo "!! no prometheus-snapshot data - inspect ${MG_OUT}/must-gather.logs and ${PAYLOAD_DIR}/gather.log"
    fi
else
    echo "!! no must-gather.local.* dir found under ${DEST_DIR} - inspect ${DEST_DIR}/must-gather.log"
fi
exit "${mg_rc}"
