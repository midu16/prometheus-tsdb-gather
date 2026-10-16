#!/usr/bin/bash
# =============================================================================
# helpers.sh -- shared plumbing for the gather test suites (SOURCE, don't run)
#
#   . "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
#
# Provides:
#   - repo / path constants (GIT_ROOT, GATHER)
#   - pass/fail/skip counters + finish() summary
#   - extract_func / extract_limit_block : pull REAL code out of gather
#     (tests exercise the shipped text, not a copy)
#   - run_gather : run the real script OFFLINE-SAFE for flag-validation
#     tests (a bogus PROM_POD makes pre-flight stop before anything is
#     copied, so these runs are side-effect-free on a live cluster and
#     also work with no cluster at all)
# =============================================================================

GIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="${GATHER:-${GIT_ROOT}/gather}"
GATHER_VERSION_EXPECTED="1.6.0"

PASSED=0
FAILED=0
SKIPPED=0

section() { echo; echo "== $*"; }
pass()    { PASSED=$((PASSED + 1)); echo "  PASS: $*"; }
fail()    { FAILED=$((FAILED + 1)); echo "  FAIL: $*"; }
skip()    { SKIPPED=$((SKIPPED + 1)); echo "  SKIP: $*"; }

# finish <label> : print the totals; returns 0 iff nothing failed
finish() {
    local label="$1"
    echo
    echo "== ${label}: ${PASSED} passed, ${FAILED} failed${SKIPPED:+, ${SKIPPED} skipped}"
    [[ ${FAILED} -eq 0 ]]
}

# extract_func <name> : define top-level function <name> from $GATHER in THIS
# shell (tests run the exact shipped code)
extract_func() {
    local fn="$1" body
    body="$(sed -n "/^${fn}() {/,/^}/p" "${GATHER}")"
    if [[ -z "${body}" ]]; then
        echo "HARNESS-ERROR: function '${fn}' not found in ${GATHER}" >&2
        return 1
    fi
    eval "${body}"
}

# extract_limit_block : pull the whole v1.6.0 dynamic-cap block (the
# LIMIT_HALTED=0 globals through the closing brace of halt_on_limit)
extract_limit_block() {
    local body
    body="$(awk '
        f && seen && $0=="}" {print; exit}
        /^LIMIT_HALTED=0/    {f=1}
        f                    {print}
        f && /    exit 0$/   {seen=1}
    ' "${GATHER}")"
    if [[ -z "${body}" || "${body}" != *"halt_on_limit"* ]]; then
        echo "HARNESS-ERROR: dynamic-cap block not found in ${GATHER}" >&2
        return 1
    fi
    eval "${body}"
}

# -----------------------------------------------------------------------------
# run_gather <flag>...
#   Run the REAL gather script offline-safe for FLAG VALIDATION tests.
#   Flag parsing + validation exits (code 64) before any cluster access, so
#   a rejection can be asserted with no cluster at all. For an ACCEPTED
#   combo the run proceeds to pre-flight, where the bogus PROM_POD (set
#   below) makes it FATAL fast - on a live cluster or without one - BEFORE
#   any byte is copied. Assert with assert_flag_accepted / assert_flag_rejected.
# Globals after the call: RG_RC (exit code), RG_OUT (stdout+stderr+gather.log)
# -----------------------------------------------------------------------------
run_gather() {
    RG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gather-test.XXXXXX")"
    local out="${RG_WORK}/out.txt"
    MUST_GATHER="${RG_WORK}/mg" \
    PROM_POD="no-such-pod-0" \
        timeout 90 bash "${GATHER}" "$@" \
        > "${out}" 2>&1
    RG_RC=$?
    RG_OUT="$(cat "${out}" 2>/dev/null)"
    [[ -f "${RG_WORK}/mg/gather.log" ]] && RG_OUT+=$'\n'"$(cat "${RG_WORK}/mg/gather.log")"
    rm -rf "${RG_WORK}"
    return 0
}

# assert_flag_rejected <label> <expected substring in the error>
assert_flag_rejected() {
    local label="$1" want="$2"
    if [[ ${RG_RC} -ne 64 ]]; then
        fail "${label}: expected exit 64, got ${RG_RC}"
        return
    fi
    if [[ "${RG_OUT}" != *"${want}"* ]]; then
        fail "${label}: exit 64 but message missing: '${want}'"
        return
    fi
    pass "${label}: exit 64 ('${want}')"
}

# assert_flag_accepted <label>
#   the flag combo was parsed: the run got PAST flag validation (rc != 64
#   and no parse/usage error) - where it stops afterwards is an environment
#   matter (no cluster / bogus pod), never a flag problem
assert_flag_accepted() {
    local label="$1"
    if [[ ${RG_RC} -eq 64 ]]; then
        fail "${label}: rejected at the flag-validation stage (rc=64)"
        return
    fi
    if [[ "${RG_OUT}" == *"unknown flag"* || "${RG_OUT}" == *"needs a value"* \
          || "${RG_OUT}" == *"cannot parse"* || "${RG_OUT}" == *"must be"* ]]; then
        fail "${label}: flag-validation error text in output (rc=${RG_RC})"
        return
    fi
    pass "${label}: accepted (rc=${RG_RC}, stopped at pre-flight/env only)"
}
