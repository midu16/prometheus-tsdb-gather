#!/usr/bin/bash
# =============================================================================
# test-07-budget-trim.sh -- the v1.8.0 pre-flight size gate (size_budget_gate)
#
# Runs the REAL size_budget_gate extracted verbatim from gather against a
# synthetic block inventory modelled on the hub cluster that motivated the
# trim policy (15d retention, ~27 GiB, 18h compacted blocks + fresh 2h blocks
# whose ULIDs sort BEFORE the last compaction output). remote_dir_bytes is
# stubbed (head size); no cluster needed.
#
# Scenarios:
#   full      DEFAULT policy: everything exported, nothing trimmed, no abort
#             even far over budget; free-space WARN when the volume is short
#   trim      opt-in policy: newest-first fit by maxTime, head kept,
#             contiguous range, EFF_SINCE_S raised, size-budget.txt contract
#   headbig   head alone > budget -> head dropped, blocks still trimmed in
#   nofit     nothing fits -> same FATAL contract as policy=fail (exit 1)
#   fail      explicit --size-policy fail keeps the v1.3.0 hard abort
#   allow     under budget -> untouched selection
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-07: size budget gate (policy full/trim/fail)"
extract_func size_budget_gate || exit 1
extract_func human_size_to_bytes || exit 1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gather-budget-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
METADATA_DIR="${WORK}/meta"; mkdir -p "${METADATA_DIR}"
TEST_LOG="${WORK}/log"
log() { echo "[gather-test] $*" >> "${TEST_LOG}"; }
MiB=$(( 1024 * 1024 ))
HEAD_BYTES=$(( 400 * MiB ))         # wal + chunks_head, split in the stub
remote_dir_bytes() { echo $(( HEAD_BYTES / 2 )); }
OUT_DIR="${WORK}"; LIMIT=0; LIMIT_ACTIVE=0
DF_AVAIL=""                         # empty = real df; else stubbed avail bytes
df() { if [[ -n "${DF_AVAIL}" ]]; then printf 'Filesystem 1-blocks Used Available Capacity Mounted\nfake 0 0 %s 0%% /\n' "${DF_AVAIL}"; else command df "$@"; fi; }

# ULID  minTime_s  maxTime_s  bytes      (inventory = ls order = ULID order)
H=3600
INV=$(printf '%s\t%s\t%s\t%s\n' \
    A0000000000000000000000001 $(( 0*H ))  $(( 18*H )) $(( 1290*MiB )) \
    A0000000000000000000000002 $(( 18*H )) $(( 36*H )) $(( 1290*MiB )) \
    A0000000000000000000000003 $(( 36*H )) $(( 54*H )) $(( 1290*MiB )) \
    A0000000000000000000000004 $(( 54*H )) $(( 56*H )) $(( 188*MiB ))  \
    A0000000000000000000000005 $(( 56*H )) $(( 58*H )) $(( 188*MiB ))  \
    A0000000000000000000000006 $(( 58*H )) $(( 60*H )) $(( 188*MiB )))
ALL="$(cut -f1 <<<"${INV}" | tr '\n' ' ')"

# run_gate <policy> <max-size> [wal]  -> GATE_RC, globals left as the gate set them
run_gate() {
    SIZE_POLICY="$1"; MAX_SIZE="$2"; MAX_BYTES="$(human_size_to_bytes "$2")"
    WAL_INCLUDED="${3:-1}"; MODE=direct; WINDOW_ACTIVE=0; SINCE=""; UNTIL=now; COMPRESS=zstd
    SELECTED_BLOCKS="${ALL}"; EXCLUDED_BLOCKS=""; BUDGET_TRIMMED=0; TRIMMED_BLOCKS=""
    EFF_SINCE_S=0; EFF_UNTIL_S=$(( 60*H ))
    : > "${TEST_LOG}"
    ( size_budget_gate "${INV}"
      declare -p SELECTED_BLOCKS EXCLUDED_BLOCKS TRIMMED_BLOCKS BUDGET_TRIMMED WAL_INCLUDED EFF_SINCE_S > "${WORK}/state" )
    GATE_RC=$?
    [[ ${GATE_RC} -eq 0 ]] && . <(sed "s/^declare -[-a-z]* /declare -g /" "${WORK}/state")
}
field() { grep -q "^$1$" "${METADATA_DIR}/size-budget.txt" && pass "size-budget.txt: $1" || fail "size-budget.txt lacks '$1' ($(cat "${METADATA_DIR}/size-budget.txt" | tr '\n' ' '))"; }
eq()    { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: expected '$3', got '$2'"; }

section "test-07/full: default policy extracts everything (no trim, no abort)"
DF_AVAIL=$(( 100 * 1024 * MiB )); run_gate full 2Gi
eq "rc 0 although 4.3 GiB > 2Gi budget" "${GATE_RC}" 0
eq "all blocks still selected" "${SELECTED_BLOCKS}" "${ALL}"
eq "nothing trimmed" "${TRIMMED_BLOCKS}" ""
eq "WAL kept" "${WAL_INCLUDED}" 1
field "decision=full"
field "projected_bytes=$(( (400 + 3*1290 + 3*188) * MiB ))"
grep -q "policy=full - extracting EVERYTHING" "${TEST_LOG}" && pass "full logged" || fail "no policy=full log line"
grep -q "LARGER than the free space" "${TEST_LOG}" && fail "spurious free-space WARN" || pass "no free-space WARN when it fits"

section "test-07/full: free-space WARN when the gather volume is too small"
DF_AVAIL=$(( 1024 * MiB )); run_gate full 2Gi
eq "rc 0 (WARN, not FATAL)" "${GATE_RC}" 0
eq "all blocks still selected" "${SELECTED_BLOCKS}" "${ALL}"
grep -q "LARGER than the free space on the gather volume" "${TEST_LOG}" && pass "free-space WARN logged" || fail "no free-space WARN"
field "gather_volume_avail_bytes=$(( 1024 * MiB ))"
DF_AVAIL=$(( 100 * 1024 * MiB ))

section "test-07/trim: opt-in policy keeps newest data (2Gi budget)"
run_gate trim 2Gi
eq "rc 0 (no abort)" "${GATE_RC}" 0
# head 400 + 3x188 = 964 MiB; next newest (block 3, 1290) does not fit -> stop
eq "kept = the three 2h blocks (chronological)" "${SELECTED_BLOCKS}" "A0000000000000000000000004 A0000000000000000000000005 A0000000000000000000000006 "
eq "trimmed = the older 18h blocks" "$(tr ' ' '\n' <<<"${TRIMMED_BLOCKS}" | grep . | sort | tr '\n' ' ')" "A0000000000000000000000001 A0000000000000000000000002 A0000000000000000000000003 "
eq "WAL kept" "${WAL_INCLUDED}" 1
eq "effective since raised to oldest kept block" "${EFF_SINCE_S}" $(( 54*H ))
field "decision=trim"
field "projected_bytes=$(( (400 + 3*188) * MiB ))"
grep -q "policy=trim: keeping the NEWEST" "${TEST_LOG}" && pass "WARN logged" || fail "no trim WARN in log"

section "test-07/trim: newest-first is by maxTime, not ULID; contiguous (no hole-filling)"
# budget fits head + 3x2h + block3, but NOT block2 -> block1 must not sneak in
run_gate trim $(( (400 + 3*188 + 1290 + 100) ))Mi
eq "kept = block3 + 2h blocks" "${SELECTED_BLOCKS}" "A0000000000000000000000003 A0000000000000000000000004 A0000000000000000000000005 A0000000000000000000000006 "

section "test-07/headbig: head alone exceeds budget -> head dropped, blocks kept"
HEAD_BYTES=$(( 3000 * MiB )); run_gate trim 2Gi; HEAD_BYTES=$(( 400 * MiB ))
eq "rc 0" "${GATE_RC}" 0
eq "WAL dropped" "${WAL_INCLUDED}" 0
eq "kept = block3 + 2h blocks" "${SELECTED_BLOCKS}" "A0000000000000000000000003 A0000000000000000000000004 A0000000000000000000000005 A0000000000000000000000006 "

section "test-07/nofit: nothing fits -> FATAL like policy=fail"
run_gate trim 100Mi 0
eq "rc 1" "${GATE_RC}" 1
grep -q "FATAL: projected must-gather TSDB export exceeds size budget" "${TEST_LOG}" && pass "stable FATAL line" || fail "no FATAL line"
field "decision=deny"

section "test-07/fail: explicit policy=fail keeps the hard abort"
run_gate fail 2Gi
eq "rc 1" "${GATE_RC}" 1
field "decision=deny"

section "test-07/allow: under budget -> selection untouched"
run_gate trim 64Gi
eq "rc 0" "${GATE_RC}" 0
eq "all blocks selected" "${SELECTED_BLOCKS}" "${ALL}"
field "decision=allow"

section "test-07/limit-default: --limit default follows the policy (real script)"
# runs the REAL policy validation + limit-default resolution block verbatim
limit_for() {  # <policy|""> <explicit limit|""> -> echoes LIMIT_ACTIVE:LIMIT
    ( SIZE_POLICY="$1"; GATHER_LIMIT="$2"
      eval "$(sed -n '/^SIZE_POLICY="\${SIZE_POLICY:-/,/^\[\[ -n "\${GATHER_LIMIT:-}" \]\]/p' "${GATHER}")"
      eval "$(awk '/^case "\$\{SIZE_POLICY\}" in$/{f=1} f{print} f&&/^LIMIT_ACTIVE=0$/{g=1} g&&/^fi$/{exit}' "${GATHER}")"
      echo "${LIMIT_ACTIVE}:${LIMIT}" )
}
eq "default (full) -> limit off"          "$(limit_for "" "")"       "0:0"
eq "full + explicit 10Gi -> limit on"     "$(limit_for full 10Gi)"   "1:10Gi"
eq "trim -> 4GB default limit"            "$(limit_for trim "")"     "1:4GB"
eq "fail -> 4GB default limit"            "$(limit_for fail "")"     "1:4GB"
eq "warn -> 4GB default limit"            "$(limit_for warn "")"     "1:4GB"

finish "test-07-budget-trim"
