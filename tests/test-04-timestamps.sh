#!/usr/bin/bash
# =============================================================================
# test-04-timestamps.sh -- unit matrix for the --since/--until parsers
# (parse_rel_seconds + parse_ts_seconds, extracted verbatim from gather)
# plus script-level window validation.
#
# Proves the v1.6.0 size work did NOT disturb the time-bounding logic:
# Prometheus letter durations, GNU-date prose, RFC3339, epoch, 'now'.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-04: parse_ts_seconds"
extract_func parse_rel_seconds || exit 1
extract_func parse_ts_seconds  || exit 1

TOL=10   # seconds of slack for now-relative values
NOW=$(date -u +%s)

check_ts() {
    local in="$1" want="$2" how="$3" got rc
    got="$(parse_ts_seconds "${in}")"; rc=$?
    case "${how}" in
        exact)
            if [[ ${rc} -eq 0 && "${got}" == "${want}" ]]; then
                pass "'${in}' -> ${got}"
            else
                fail "'${in}' -> '${got}' rc=${rc} (want ${want})"
            fi
            ;;
        near)
            if [[ ${rc} -eq 0 && -n "${got}" ]] && (( got > want - TOL && got < want + TOL )); then
                pass "'${in}' -> $(( NOW - got ))s in the past (want ~$(( NOW - want ))s)"
            else
                fail "'${in}' -> '${got}' rc=${rc} (want ~${want})"
            fi
            ;;
    esac
}

check_ts "now"                      "${NOW}"                          near
check_ts "30d"                      "$(( NOW - 30 * 86400 ))"         near
check_ts "29d"                      "$(( NOW - 29 * 86400 ))"         near
check_ts "6h"                       "$(( NOW - 6 * 3600 ))"           near
check_ts "90m"                      "$(( NOW - 90 * 60 ))"            near
check_ts "12s"                      "$(( NOW - 12 ))"                 near
check_ts "1w"                       "$(( NOW - 7 * 86400 ))"          near
check_ts "3d12h"                    "$(( NOW - 3 * 86400 - 12 * 3600 ))" near
check_ts "2026-09-29T10:00:00Z"     "$(date -u -d 2026-09-29T10:00:00Z +%s)" exact
check_ts "24 hours ago"             "$(( NOW - 86400 ))"              near
check_ts "2 hours ago"              "$(( NOW - 7200 ))"               near
check_ts "1727000000"               1727000000                        exact

# failures: empty + garbage emit nothing and return non-zero
if [[ -z "$(parse_ts_seconds '')" ]]; then pass "empty input -> no output"; else fail "empty input produced output"; fi
if [[ -z "$(parse_ts_seconds 'garbage!!!' 2>/dev/null)" ]]; then pass "garbage -> no output"; else fail "garbage produced output"; fi

section "test-04: script-level window validation (real script)"
run_gather --since 2026-10-16T00:00:00Z --until 2026-10-15T00:00:00Z
assert_flag_rejected "since > until" "is after --until"
run_gather --since 30d --until 29d
assert_flag_accepted "canonical 30d/29d window"

finish "test-04-timestamps"
