#!/usr/bin/bash
# =============================================================================
# test-05-limit-monitor.sh -- the v1.6.0 --limit extraction logic
#
# Runs the REAL dynamic-cap block (globals + local_dir_bytes, proc_match_pids,
# kill_pat, monitor_limit, extract_member, extract_members_limited,
# halt_on_limit) extracted verbatim from gather, with `oc` stubbed as a bash
# function that produces real tar streams from a fake "remote" tree.
#
# Scenarios:
#   pre      pre-transfer cap check halts BEFORE a member starts (no write)
#   mid      a mid-transfer breach kills the pipeline, drops the partial
#            in-flight member, exits cleanly (rc=0) with limit-halt.txt
#   under    everything fits: every member copied byte-identical, no halt
#   failretry a hard transfer failure is retried once, then FATAL (rc=1)
#   torntail the expected live-WAL 'file changed as we read it' error is
#            classified as rc=2 (torn tail): warning, member kept, run continues
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-05: dynamic size cap (--limit) extraction monitor"
extract_limit_block || exit 1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gather-limit-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
TEST_LOG="${WORK}/test.log"
: > "${TEST_LOG}"

# cluster-side stubs (log goes to ${TEST_LOG} so asserts can grep it)
log()  { echo "[gather-test] $*" | tee -a "${TEST_LOG}"; }
warn() { echo "[gather-test] WARN: $*" | tee -a "${TEST_LOG}"; }
fail() { echo "[gather-test] FATAL: $*" | tee -a "${TEST_LOG}"; exit 1; }

# common fake-remote layout: two block dirs (ULID-named) of known sizes
B1="AAAAAAAAAAAAAAAAAAAAAAAA"
B2="BBBBBBBBBBBBBBBBBBBBBBBB"
make_fake_remote() {
    FAKE_ROOT="${WORK}/remote"
    mkdir -p "${FAKE_ROOT}/${B1}" "${FAKE_ROOT}/${B2}"
    echo meta > "${FAKE_ROOT}/${B1}/meta.json"
    echo meta > "${FAKE_ROOT}/${B2}/meta.json"
    dd if=/dev/urandom of="${FAKE_ROOT}/${B1}/chunk1" bs=1M count=200 status=none
    dd if=/dev/urandom of="${FAKE_ROOT}/${B2}/chunk1" bs=1M count=2 status=none
    REMOTE_ROOT="${FAKE_ROOT}"
}

# the stock oc stub: 'oc exec ... -- tar cf - -C <root> <member>'
oc_ok() {
    oc() {
        local -a a=("$@") i=0 rest
        while [[ "${a[i]}" != "--" ]]; do i=$((i + 1)); done
        rest=("${a[@]:i+1}")
        tar cf - -C "${rest[${#rest[@]}-2]}" "${rest[-1]}"
    }
}

# scenario runner: (fresh per scenario) sets up dirs, stubs, invokes the
# real extract_members_limited in a subshell (halt_on_limit exits IT)
scenario() {
    local name="$1"; shift
    local out="${WORK}/${name}"
    OUT_DIR="${out}/mg"
    TSDB_OUT_DIR="${OUT_DIR}/prometheus-snapshot"
    METADATA_DIR="${OUT_DIR}/prometheus-metadata"
    DIRECT_TARGET="${TSDB_OUT_DIR}/TS"
    mkdir -p "${METADATA_DIR}" "${DIRECT_TARGET}"
    MON_NS=test PROM_POD=test PROM_CONTAINER=test
    GATHER_LIMIT_POLL=0.2
    LIMIT_ACTIVE=1
    LIMIT_HALTED=0 LIMIT_HALT_AT="" LIMIT_HALT_REASON=""
    COMPLETED_MEMBERS="" MEMBER_INFLIGHT=""
    : > "${TEST_LOG}"
    (
        "${1}"                       # oc stub setup function
        ( extract_members_limited )  # the real code under test
    )
    SCENARIO_RC=$?
    SCENARIO_DIR="${DIRECT_TARGET}"
    SCENARIO_META="${METADATA_DIR}"
}

declare -A MEMBER_SIZE=()
CP_MEMBERS=""
LIMIT="" LIMIT_BYTES=0 BLOCK_INV="" SELECTED_BLOCKS="" WAL_INCLUDED=0

# ---------------------------------------------------------------- pre ------
section "test-05/pre: pre-transfer cap check"
oc_ok_pre() { oc_ok; }
make_fake_remote
MEMBER_SIZE=(); MEMBER_SIZE["${B1}"]=209715200      # inventory: 200 MiB
CP_MEMBERS="${B1} ${B2}"
LIMIT=10Mi LIMIT_BYTES=10485760
scenario pre oc_ok_pre
if [[ ${SCENARIO_RC} -eq 0 && ! -e "${SCENARIO_DIR}/${B1}" && ! -e "${SCENARIO_DIR}/${B2}" \
      && -f "${SCENARIO_META}/limit-halt.txt" ]] \
   && grep -q "pre-transfer" "${SCENARIO_META}/limit-halt.txt"; then
    pass "pre: rc=0, nothing written, limit-halt.txt reason=pre-transfer"
else
    fail "pre: rc=${SCENARIO_RC} dir=[$(ls "${SCENARIO_DIR}" 2>/dev/null | tr '\n' ' ')]"
fi

# ----------------------------------------------------------------- mid -----
section "test-05/mid: mid-transfer breach"
MEMBER_SIZE=(); MEMBER_SIZE["${B1}"]=0             # inventory LIES: est 0
CP_MEMBERS="${B1} ${B2}"
LIMIT=10Mi LIMIT_BYTES=10485760
scenario mid oc_ok_pre
if [[ ${SCENARIO_RC} -eq 0 && ! -e "${SCENARIO_DIR}/${B1}" \
      && -f "${SCENARIO_META}/limit-halt.txt" ]] \
   && grep -q "mid-transfer" "${SCENARIO_META}/limit-halt.txt" \
   && grep -q "LIMIT BREACH" "${TEST_LOG}"; then
    pass "mid: rc=0 after breach; pipeline killed; partial member dropped; limit-halt.txt reason=mid-transfer"
else
    fail "mid: rc=${SCENARIO_RC} dir=[$(ls "${SCENARIO_DIR}" 2>/dev/null | tr '\n' ' ')]"
fi

# ------------------------------------------------------------- under -------
section "test-05/under: under-cap full copy"
MEMBER_SIZE=(); MEMBER_SIZE["${B1}"]=209715200 MEMBER_SIZE["${B2}"]=2097152
CP_MEMBERS="${B2} ${B1}"
LIMIT=4GB LIMIT_BYTES=4294967296
scenario under oc_ok_pre
if [[ ${SCENARIO_RC} -eq 0 && ! -f "${SCENARIO_META}/limit-halt.txt" ]] \
   && cmp -s "${FAKE_ROOT}/${B1}/chunk1" "${SCENARIO_DIR}/${B1}/chunk1" \
   && cmp -s "${FAKE_ROOT}/${B2}/chunk1" "${SCENARIO_DIR}/${B2}/chunk1"; then
    pass "under: rc=0, both members byte-identical, no halt record"
else
    fail "under: rc=${SCENARIO_RC} dir=[$(ls "${SCENARIO_DIR}" 2>/dev/null | tr '\n' ' ')]"
fi

# ------------------------------------------------------------- failretry ---
section "test-05/failretry: hard failure retried once, then FATAL"
oc_always_fail() {
    oc() { echo "tar: remote exploded" >&2; return 2; }
}
MEMBER_SIZE=(); MEMBER_SIZE["${B1}"]=0
CP_MEMBERS="${B1}"
LIMIT=4GB LIMIT_BYTES=4294967296
scenario retry oc_always_fail
if [[ ${SCENARIO_RC} -eq 1 ]] && grep -q "failed twice" "${TEST_LOG}"; then
    pass "failretry: rc=1 after one retry, FATAL 'failed twice'"
else
    fail "failretry: rc=${SCENARIO_RC} (want 1); log tail: $(tail -2 "${TEST_LOG}" | tr '\n' ' | ')"
fi

# --------------------------------------------------------------- torntail --
section "test-05/torntail: live-WAL torn-tail classified rc=2, run continues"
oc_torntail() {
    oc() {
        local -a a=("$@") i=0 rest rc
        while [[ "${a[i]}" != "--" ]]; do i=$((i + 1)); done
        rest=("${a[@]:i+1}")
        tar cf - -C "${rest[${#rest[@]}-2]}" "${rest[-1]}"
        rc=$?
        echo "tar: ${rest[-1]}/00000001: file changed as we read it" >&2
        echo "command terminated with exit code 1" >&2
        return 1        # oc reports the remote non-zero exit
    }
}
MEMBER_SIZE=(); MEMBER_SIZE["${B1}"]=0
CP_MEMBERS="${B1}"
LIMIT=4GB LIMIT_BYTES=4294967296
scenario torntail oc_torntail
if [[ ${SCENARIO_RC} -eq 0 ]] && [[ -f "${SCENARIO_DIR}/${B1}/meta.json" ]] \
   && grep -q "torn-tail" "${TEST_LOG}" && [[ ! -f "${SCENARIO_META}/limit-halt.txt" ]]; then
    pass "torntail: rc=0, WARN logged, member kept, no halt"
else
    fail "torntail: rc=${SCENARIO_RC} logged=$(grep -c torn-tail "${TEST_LOG}")"
fi

finish "test-05-limit-monitor"
