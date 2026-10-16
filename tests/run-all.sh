#!/usr/bin/bash
# =============================================================================
# run-all.sh -- the whole gather test suite
#
#   ./tests/run-all.sh              # unit suites + E2E (E2E self-skips w/o cluster)
#   ./tests/run-all.sh --unit-only  # no cluster access at all
#   ./tests/run-all.sh --e2e-only   # only the live oc adm must-gather matrix
#
# Exit code: nonzero iff any executed suite failed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODE="all"
case "${1:-}" in
    --unit-only) MODE="unit" ;;
    --e2e-only)  MODE="e2e" ;;
    "")          MODE="all" ;;
    *) echo "usage: $0 [--unit-only|--e2e-only]" >&2; exit 2 ;;
esac

OVERALL=0
run_suite() {
    local t="$1"
    echo
    echo "#"
    echo "#  $t"
    echo "#"
    bash "${t}"
    local rc=$?
    (( rc )) && OVERALL=1
    return 0
}

if [[ ${MODE} == unit || ${MODE} == all ]]; then
    for t in test-01-usage.sh test-02-flag-parsing.sh test-03-human-size.sh \
             test-04-timestamps.sh test-05-limit-monitor.sh; do
        run_suite "${t}"
    done
fi

if [[ ${MODE} == e2e || ${MODE} == all ]]; then
    run_suite test-06-e2e-must-gather.sh
fi

echo
if [[ ${OVERALL} -eq 0 ]]; then
    echo "ALL SUITES GREEN"
else
    echo "SOME SUITES FAILED (see above)"
fi
exit "${OVERALL}"
