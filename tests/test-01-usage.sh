#!/usr/bin/bash
# =============================================================================
# test-01-usage.sh -- the help/usage contract (no cluster needed)
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-01: usage / help"

help_out="$(bash "${GATHER}" --help 2>&1)"; rc=$?
if [[ ${rc} -eq 0 ]]; then pass "--help exits 0"; else fail "--help exited ${rc}"; fi

# the exact --limit contract line the operator asked for
[[ "${help_out}" == *"--limit <size>"* ]] \
    && pass "usage mentions '--limit <size>'" \
    || fail "usage missing '--limit <size>'"

[[ "${help_out}" == *"[default: 4GB, 0: unlimited]"* ]] \
    && pass "usage carries '[default: 4GB, 0: unlimited]'" \
    || fail "usage missing '[default: 4GB, 0: unlimited]'"

# every flag surface is documented
for f in --max-size --size-policy --limit --since --until --include-wal \
         --compress --max-gb --at --strict-notready "-h, --help"; do
    [[ "${help_out}" == *"${f}"* ]] \
        && pass "usage documents '${f}'" \
        || fail "usage missing '${f}'"
done

short_out="$(bash "${GATHER}" -h 2>&1)"; rc=$?
[[ ${rc} -eq 0 && "${short_out}" == *"gather [options]"* ]] \
    && pass "-h exits 0 and prints usage" \
    || fail "-h: rc=${rc}"

finish "test-01-usage"
