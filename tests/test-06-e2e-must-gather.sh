#!/usr/bin/bash
# =============================================================================
# test-06-e2e-must-gather.sh -- E2E: the REAL production invocation
#
#   oc adm must-gather --image <image> --dest-dir <case dir> \
#       -- /usr/bin/gather <flags>
#
# Runs a per-flag matrix against the LIVE cluster. Skips gracefully (exit 0)
# when there is no cluster / no oc / no kubeconfig here; set E2E_REQUIRED=1
# to hard-fail in that situation (CI).
#
# Env:
#   E2E_IMAGE        payload image     (default quay.io/midu/prometheus-tsdb-gather:latest)
#   E2E_DEST         output root       (default tests/.e2e-out)
#   E2E_TIMEOUT      per-run framework --timeout (default 25m)
#   E2E_KUBECONFIG   operator kubeconfig for the CLIENT 'oc' (payload pod
#                    falls back to its in-cluster cluster-admin SA token)
#   E2E_QUICK        1 = only cases in E2E_QUICK_CASES (default "01 02 03 04")
#   E2E_REQUIRED     1 = exit nonzero when the suite must skip
#
# PRE-REQUISITE: the image must be built from THIS checkout (payload version
# line 2 == ${GATHER_VERSION_EXPECTED}), otherwise the new --limit flag is
# not in the image and cases fail with 'unknown flag'. Rebuild:
#   podman build -t ${E2E_IMAGE} -f ${GIT_ROOT}/Containerfile ${GIT_ROOT}
#   podman push ${E2E_IMAGE}
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

IMAGE="${E2E_IMAGE:-quay.io/midu/prometheus-tsdb-gather:latest}"
DEST_ROOT="${E2E_DEST:-${GIT_ROOT}/tests/.e2e-out}"
RUN_TIMEOUT="${E2E_TIMEOUT:-25m}"
VOL_PCT="${E2E_VOLUME_PERCENTAGE:-90}"
KCFG="${E2E_KUBECONFIG:-/var/apps/sno.frntdeu1.pop.starlinkisp.net/workdir/auth/kubeconfig}"
QUICK="${E2E_QUICK:-0}"
QUICK_CASES="${E2E_QUICK_CASES:-01 02 03 04}"
ABORT=0

section "test-06: E2E via oc adm must-gather (image=${IMAGE})"

gate_skip() {
    skip "$*"
    echo
    echo "== test-06: SKIPPED (no live-cluster run). Re-run on the operator workstation, or set E2E_REQUIRED=1 to hard-fail."
    [[ "${E2E_REQUIRED:-0}" == "1" ]] && exit 1
    exit 0
}
command -v oc >/dev/null 2>&1 || gate_skip "no 'oc' client in PATH"
[[ -f "${KCFG}" ]] || gate_skip "operator kubeconfig not found: ${KCFG} (override via E2E_KUBECONFIG)"
export KUBECONFIG="${KCFG}"
timeout 30 oc whoami > /dev/null 2>&1 || gate_skip "'oc whoami' failed (cluster unreachable / stale creds)"
mkdir -p "${DEST_ROOT}"

# --- assertions over one case's downloaded payload ---------------------------
# PDIR = the payload dir (contains gather.log/version/prometheus-snapshot)
have_payload() {
    PDIR="$(find "${1}" -name gather.log -type f 2>/dev/null | head -1 | xargs -r dirname)"
    if [[ -z "${PDIR:-}" || ! -f "${PDIR}/gather.log" ]]; then
        fail "no payload gather.log under ${1} (image pull failure? see ${1}/must-gather.logs and ${1}/framework.log)"
        return 1
    fi
    return 0
}
check_no_secret_leak() {
    if find "${PDIR}" -iname '*kubeconfig*' 2>/dev/null | grep -q .; then
        fail "kubeconfig leaked into the payload (must-gather rule 4)"
    else
        pass "no kubeconfig/credential leak in the payload"
    fi
}
check_version() {
    local v1 v2
    v1="$(head -1 "${PDIR}/version" 2>/dev/null)"
    v2="$(sed -n 2p "${PDIR}/version" 2>/dev/null)"
    if [[ "${v1}" == "prometheus-tsdb-must-gather" && "${v2}" == "${GATHER_VERSION_EXPECTED}" ]]; then
        pass "payload version ${v2}"
    else
        fail "payload version '${v2:-<missing>}' (want ${GATHER_VERSION_EXPECTED}) - the image is not from THIS checkout; rebuild + push:"
        echo "      podman build -t ${IMAGE} -f ${GIT_ROOT}/Containerfile ${GIT_ROOT} && podman push ${IMAGE}"
        ABORT=1
    fi
}
check_done() {
    if grep -q "DONE" "${PDIR}/gather.log"; then
        pass "clean run (DONE marker in gather.log)"
    else
        fail "no DONE marker in gather.log (tail: $(tail -3 "${PDIR}/gather.log" | tr '\n' ' | '))"
    fi
}
check_field() {   # <file> <fixed pattern>
    if grep -qF -- "${2}" "${PDIR}/${1}" 2>/dev/null; then
        pass "${1}: '${2}'"
    else
        fail "${1}: missing '${2}'"
    fi
}
# every shipped block dir on disk must be complete (meta.json present) -
# a partial block would make the TSDB unopenable
check_blocks_ok() {
    local d b bad=0
    for d in "${PDIR}"/prometheus-snapshot/*/; do
        [[ -d "${d}" ]] || continue
        for b in "${d}"*/; do
            [[ -d "${b}" ]] || continue
            if [[ "$(basename "${b}")" =~ ^[0-9A-Z]{26}$ && ! -f "${b}meta.json" ]]; then
                bad=1
            fi
        done
    done
    (( bad )) && fail "partial block dir survived (missing meta.json) - the copy would not open" \
           || pass "structural: every block dir has meta.json (copy opens)"
}

# every shipped archive + tree file re-hashes cleanly against the shipped
# SHA256SUMS (the payload wrote these from inside the gather pod)
check_sums() {
    local dir="${PDIR}/prometheus-snapshot"
    if [[ ! -f "${dir}/SHA256SUMS" ]]; then
        fail "SHA256SUMS missing under prometheus-snapshot/"
        return
    fi
    if ( cd "${dir}" && sha256sum -c SHA256SUMS --quiet ); then
        pass "sha256sum -c SHA256SUMS: $(wc -l < "${dir}/SHA256SUMS") entries verified (archive + tree)"
    else
        fail "sha256sum -c SHA256SUMS FAILED (corrupt transfer?)"
    fi
}

# --- the production invocation, verbatim --------------------------------------
#   NOTE: --volume-percentage (framework disk-usage checker, default 70) is
#   raised: on a busy SNO node the pod volume can already be >70% full at
#   pod start, in which case the framework KILLS the payload a few ms in
#   (observed: 'Disk usage exceeds the volume percentage of 70 ... terminating'
#   + SIGKILL, yet framework rc=0). Override via E2E_VOLUME_PERCENTAGE.
run_case() {   # <name> <flags...>
    local name="$1"; shift
    CDIR="${DEST_ROOT}/${name}"
    RAN=1
    rm -rf "${CDIR}"; mkdir -p "${CDIR}"
    echo "  >>> ${name}: oc adm must-gather --image ${IMAGE} --dest-dir ${CDIR} -- /usr/bin/gather $*"
    ( cd "${CDIR}" && timeout "${RUN_TIMEOUT}" oc adm must-gather \
        --image "${IMAGE}" --dest-dir "$(pwd)" \
        --volume-percentage "${VOL_PCT}" \
        -- /usr/bin/gather "$@" ) > "${CDIR}/framework.log" 2>&1
    FRAMEWORK_RC=$?
    echo "  >>> ${name}: framework rc=${FRAMEWORK_RC}"
}
run_optional() {  # <case id> <name> <flags...> : honors ABORT + E2E_QUICK
    local id="$1" name="$2"; shift 2
    RAN=0
    if (( ABORT )); then skip "${name} (skipped after version abort)"; return 0; fi
    if [[ ${QUICK} == 1 && " ${QUICK_CASES} " != *" ${id} "* ]]; then
        skip "${name} (E2E_QUICK=1; include via E2E_QUICK_CASES)"
        return 0
    fi
    run_case "${name}" "$@"
}

# =============================================================================
# CASE MATRIX
#   every case also re-proves the common contract (payload dir present, no
#   secret leak); version is checked in case 01 (same image for all runs).
#
#   NOTE: cases pass --max-size none unless they are ABOUT the pre-flight
#   budget (06/07), so the default 2Gi budget cannot shadow the flag under
#   test. The DEFAULT 4GB --limit stays active everywhere (that is the new
#   default) - on a cluster whose windowed export exceeds 4GB, case 01/02
#   would halt by design (limit-halt.txt) instead of reporting DONE.
# =============================================================================

section "case 01: full export, all defaults (limit defaults to 4GB)"
run_optional 01 e2e-01-default --max-size none
if (( RAN )) && have_payload "${CDIR}"; then
    check_version
    check_done
    check_no_secret_leak
    check_field prometheus-metadata/extraction-mode.json "window_active=0"
    check_field prometheus-metadata/extraction-mode.json "limit=4GB"
    check_field prometheus-metadata/extraction-mode.json "limit_active=1"
    NBLOCKS=$(find "${PDIR}/prometheus-snapshot" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | grep -cE '/[0-9A-Z]{26}$' || true)
    if [[ ${NBLOCKS:-0} -ge 1 ]]; then pass "exported ${NBLOCKS} block dir(s)"; else fail "no block dirs in the export"; fi
    check_blocks_ok
    [[ -f "${PDIR}/prometheus-metadata/time-window.json" ]] && pass "time-window.json present" || fail "time-window.json missing"
    check_sums
fi

section "case 02: the operator's production window --since 30d --until 29d"
run_optional 02 e2e-02-window --max-size none --since 30d --until 29d
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_no_secret_leak
    check_field prometheus-metadata/extraction-mode.json "window_active=1"
    [[ -f "${PDIR}/prometheus-metadata/retention.txt" ]] && pass "retention.txt present" || fail "retention.txt missing"
    grep -q '"window_clamped"' "${PDIR}/prometheus-metadata/time-window.json" 2>/dev/null \
        && pass "time-window.json carries window_clamped" || fail "time-window.json malformed"
    check_blocks_ok
fi

section "case 03: --limit 0 (unlimited export)"
run_optional 03 e2e-03-limit-unlimited --max-size none --limit 0
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "limit_active=0"
    [[ -f "${PDIR}/prometheus-metadata/limit-halt.txt" ]] && fail "limit-halt.txt present although --limit 0" || pass "no limit-halt.txt (cap disabled)"
fi

section "case 04: --limit 1Mi (guaranteed breach -> clean halt, exit 0)"
run_optional 04 e2e-04-limit-halt --max-size none --limit 1Mi
if (( RAN )) && have_payload "${CDIR}"; then
    if [[ ${FRAMEWORK_RC} -eq 0 ]]; then
        pass "framework rc=0 - the pod did NOT crash (clean halt contract)"
    else
        fail "framework rc=${FRAMEWORK_RC} (want 0: halt must exit cleanly)"
    fi
    if [[ -f "${PDIR}/prometheus-metadata/limit-halt.txt" ]]; then
        pass "limit-halt.txt written"
        hr="$(grep '^halt_reason=' "${PDIR}/prometheus-metadata/limit-halt.txt" 2>/dev/null | cut -d= -f2-)"
        if [[ "${hr}" =~ ^(pre-transfer|mid-transfer) ]]; then
            pass "halt_reason recorded: ${hr:0:60}..."
        else
            fail "halt_reason missing/unexpected: ${hr:-(empty)}"
        fi
        pass "halt fields: $(grep -E '^(limit=|halt_at_member=|members_completed=|members_skipped=)' "${PDIR}/prometheus-metadata/limit-halt.txt" | tr '\n' ' | ')"
    else
        fail "limit-halt.txt missing (expected a halt at 1Mi)"
    fi
    grep -q "DONE" "${PDIR}/gather.log" && fail "run reported DONE although the cap was hit" || pass "no DONE marker (halt before metadata phase, as designed)"
    check_blocks_ok
fi

section "case 05: --compress none (no archive artifact)"
run_optional 05 e2e-05-compress-none --max-size none --limit 0 --compress none
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "compress=none"
    if find "${PDIR}/prometheus-snapshot" -name '*.tar.*' 2>/dev/null | grep -q .; then
        fail "archive found although --compress none"
    else
        pass "no .tar.* archive (compress=none)"
    fi
fi

section "case 06: budget miss + --size-policy warn (deny but continue)"
run_optional 06 e2e-06-budget-warn --max-size 1MB --size-policy warn --limit 0
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/size-budget.txt "decision=deny"
    check_field prometheus-metadata/size-budget.txt "policy=warn"
    grep -q "policy=warn, continuing" "${PDIR}/gather.log" \
        && pass "budget warn-and-continue logged" || fail "no warn-and-continue log line"
fi

section "case 07: budget miss + default policy=fail (pre-copy FATAL, nothing ships)"
run_optional 07 e2e-07-budget-fail --max-size 1MB --limit 0
if (( RAN )) && have_payload "${CDIR}"; then
    if [[ ${FRAMEWORK_RC} -ne 0 ]]; then
        pass "framework rc=${FRAMEWORK_RC} (non-zero: budget refusal propagated)"
    else
        fail "framework rc=0 although the budget gate must refuse (policy=fail)"
    fi
    grep -q "exceeds size budget" "${PDIR}/gather.log" && pass "FATAL budget line present" || fail "no 'exceeds size budget' line"
    check_field prometheus-metadata/size-budget.txt "decision=deny"
    NBLOCKS=$(find "${PDIR}/prometheus-snapshot" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | grep -cE '/[0-9A-Z]{26}$' || true)
    [[ ${NBLOCKS:-0} -eq 0 ]] && pass "no blocks shipped on a refused run" || fail "${NBLOCKS} block(s) shipped despite the refusal"
fi

section "case 08: --include-wal false (head dirs stay in the pod)"
run_optional 08 e2e-08-include-wal-false --max-size none --limit 0 --include-wal false
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    grep -q '"include_wal": false' "${PDIR}/prometheus-metadata/time-window.json" 2>/dev/null \
        && pass "time-window.json: include_wal=false" || fail "time-window.json does not say include_wal=false"
    if find "${PDIR}/prometheus-snapshot" -mindepth 2 -maxdepth 2 -type d -name wal 2>/dev/null | grep -q .; then
        fail "wal/ dir shipped although --include-wal false"
    else
        pass "no wal/ dir in the export"
    fi
fi

section "case 09: --strict-notready (healthy cluster: still runs)"
run_optional 09 e2e-09-strict-notready --max-size none --limit 0 --strict-notready
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "strict_notready=true"
fi

section "case 10: legacy guards --max-gb / --at on the local copy"
run_optional 10 e2e-10-legacy-guards --max-size none --limit 0 --max-gb 100 --at "2 days ago"
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "at_timestamp=2 days ago"
    check_field prometheus-metadata/export-guards.txt "max_cap_gi=100"
    check_blocks_ok
fi

section "case 11: the operator's EXACT production invocation (--limit 1234GB)"
#   note: NO --max-size override on purpose - the default 2Gi pre-flight
#   budget gate is part of the tested path (on a >2Gi cluster this case
#   would refuse at the budget, which is correct behavior)
run_optional 11 e2e-11-production-flags --since 30d --until 29d --limit 1234GB
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "window_active=1"
    check_field prometheus-metadata/extraction-mode.json "limit=1234GB"
    check_field prometheus-metadata/extraction-mode.json "limit_active=1"
    check_field prometheus-metadata/extraction-mode.json "limit_bytes=1324997410816"
    grep -q '^decision=\(allow\|deny\)$' "${PDIR}/prometheus-metadata/size-budget.txt" 2>/dev/null \
        && pass "size-budget gate decided: $(grep '^decision=' "${PDIR}/prometheus-metadata/size-budget.txt")" \
        || fail "size-budget.txt has no decision"
    check_sums
fi

section "case 12: --compress gzip (archive + SHA256SUMS verify)"
run_optional 12 e2e-12-compress-gzip --max-size none --limit 0 --compress gzip
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    check_field prometheus-metadata/extraction-mode.json "compress=gzip"
    if find "${PDIR}/prometheus-snapshot" -name '*.tar.gz' 2>/dev/null | grep -q .; then
        pass ".tar.gz archive present"
        check_sums
    else
        fail "no .tar.gz archive although --compress gzip"
    fi
fi

section "case 13: --include-wal true (head dirs must leave the pod)"
run_optional 13 e2e-13-include-wal-true --max-size none --limit 0 --include-wal true
if (( RAN )) && have_payload "${CDIR}"; then
    check_done
    grep -q '"include_wal": true' "${PDIR}/prometheus-metadata/time-window.json" 2>/dev/null \
        && pass "time-window.json: include_wal=true" || fail "time-window.json does not say include_wal=true"
    if [[ -d "${PDIR}/prometheus-snapshot"/*'/wal' ]]; then
        pass "wal/ dir shipped"
    else
        fail "wal/ dir missing although --include-wal true"
    fi
fi

finish "test-06-e2e-must-gather"

