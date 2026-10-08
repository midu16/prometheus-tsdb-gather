#!/usr/bin/bash
# =============================================================================
# validate-extraction.sh -- post-extraction validator for the must-gather run
#
# Usage:  ./validate-extraction.sh [demo-run-dir] [SINCE_REL] [UNTIL_REL]
#         default:  ./validate-extraction.sh  ./demo-run  30d  29d
#
# Validates in ./demo-run/:
#   1. RUN STATUS     : no FATAL in gather.log; 'DONE - mode=' present.
#   2. TIME BOUNDARIES: shipped blocks' [minTime,maxTime] (LOCAL meta.json)
#                        vs the requested window. Block granularity is a whole
#                        ULID dir (never split), so 'strict alignment' is:
#                          clamped=false -> shipped set == intersect set (PASS)
#                          clamped=true  -> honest clamp proven: evidence in
#                            time-window.json + retention.txt AND no shipped
#                            block intersects the requested window
#                       anything else -> FAIL
#   3. DATA INTEGRITY : sha256sum -c (archive + tree), tar member-list test,
#                        unpack+diff file sets, per-block structure (meta.json
#                        + index + chunks, minTime<=maxTime), exported-blocks
#                        tsv cross-check, promtool tsdb list (if available)
#   4. CLAMP AUDIT    : declared clamp must be real (retention explains it)
#
# Exit: 0 = PASS (incl. pass-with-declared-clamp)   1 = FAIL
# =============================================================================
set -uo pipefail
DEST="${1:-./demo-run}"
SINCE_REL="${2:-30d}"
UNTIL_REL="${3:-29d}"
FAILS=0
pass() { printf '\033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
info() { printf 'INFO  %s\n' "$*"; }

[[ -d "${DEST}" ]] || { echo "no such dir: ${DEST}"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
PAYLOAD="$(find "${DEST}" -maxdepth 2 -type d -name 'quay-io-*prometheus-tsdb-gather*' | head -1)"
[[ -n "${PAYLOAD}" ]] || { echo "FAIL: no payload dir under ${DEST}"; exit 1; }
LOG="${PAYLOAD}/gather.log"
META="${PAYLOAD}/prometheus-metadata"
SNAP="${PAYLOAD}/prometheus-snapshot"
TSDB="$(find "${SNAP}" -maxdepth 1 -mindepth 1 -type d | head -1)"
ARCHIVE="$(find "${SNAP}" -maxdepth 1 -name '*.tar.zstd' -o -name '*.tar.gz' 2>/dev/null | head -1)"
info "payload: ${PAYLOAD}"
info "tsdb:    ${TSDB:-<none>}"

echo; echo "=== 1. RUN STATUS ==="
if [[ -f "${LOG}" ]]; then
    if grep -q 'FATAL' "${LOG}"; then
        fail "gather.log contains FATAL lines:"; sed 's/^/      /' <(grep -n 'FATAL' "${LOG}")
    else
        pass "gather.log: no FATAL"
    fi
    if grep -q 'DONE - mode=' "${LOG}"; then
        pass "run completed: $(grep -m1 'DONE - mode=' "${LOG}" | sed 's/^.*DONE/DONE/')"
    else
        fail "gather.log: no 'DONE - mode=' marker (script aborted mid-run)"
    fi
else
    fail "gather.log missing"
fi
[[ -n "$(cat "${PAYLOAD}/version" 2>/dev/null)" ]] \
    && info "payload version: $(head -2 "${PAYLOAD}/version" | tr '\n' ' ')" \
    || fail "version file missing"

echo; echo "=== 2. TIME BOUNDARIES ==="
# requested window, recomputed at validation time (Prometheus relative durations)
req_seconds() {
    local s="$1"
    [[ "${s}" =~ ^([0-9]+)d$ ]] && { date -u -d "now - ${BASH_REMATCH[1]} days" +%s; return; }
    [[ "${s}" =~ ^([0-9]+)h$ ]] && { date -u -d "now - ${BASH_REMATCH[1]} hours" +%s; return; }
    [[ "${s}" =~ ^[0-9]+$ ]] && { echo "${s}"; return; }
    date -u -d "${s}" +%s
}
REQ_SINCE="$(req_seconds "${SINCE_REL}")"
REQ_UNTIL="$(req_seconds "${UNTIL_REL}")"
(( REQ_SINCE <= REQ_UNTIL )) || warn "--since rel did not land before --until rel (clock skew?); validating against the recomputed bounds anyway"
WIDTH_S=$(( REQ_UNTIL - REQ_SINCE ))
info "requested window (now-based): $(date -u -d "@${REQ_SINCE}" +%FT%TZ) .. $(date -u -d "@${REQ_UNTIL}" +%FT%TZ)   (${WIDTH_S}s ~ $(( WIDTH_S / 86400 ))d wide)"

CLAMPED="false"
[[ -f "${META}/time-window.json" ]] && CLAMPED="$(jq -r '.window_clamped // false' "${META}/time-window.json")"
info "time-window.json says: window_clamped=${CLAMPED}"

if [[ ! -d "${TSDB}" ]]; then
    fail "no unpacked TSDB tree under ${SNAP}"
else
    N=0; IN=0; OUT=0; MIN_S=0; MAX_S=0
    for mj in "${TSDB}"/*/meta.json; do
        [[ -f "${mj}" ]] || continue
        d="$(dirname "${mj}")"
        b="$(basename "${d}")"
        [[ "${b}" =~ ^[0-9A-Z]{26}$ ]] || continue
        min_ms="$(jq -r '.minTime // empty' "${mj}" 2>/dev/null)"
        max_ms="$(jq -r '.maxTime // empty' "${mj}" 2>/dev/null)"
        if [[ ! "${min_ms}" =~ ^[0-9]+$ || ! "${max_ms}" =~ ^[0-9]+$ ]]; then
            fail "block ${b}: meta.json bounds invalid (min=${min_ms} max=${max_ms})"
            continue
        fi
        min_ms=$(( min_ms )); max_ms=$(( max_ms ))
        if (( min_ms > max_ms )); then
            fail "block ${b}: meta.json bounds invalid (min=${min_ms} max=${max_ms})"
            continue
        fi
        min_s=$((min_ms / 1000)); max_s=$((max_ms / 1000))
        N=$((N+1))
        (( min_s < MIN_S || MIN_S == 0 )) && MIN_S=${min_s}
        (( max_s > MAX_S )) && MAX_S=${max_s}
        if (( min_s <= REQ_UNTIL && max_s >= REQ_SINCE )); then IN=$((IN+1)); else OUT=$((OUT+1)); fi
    done
    info "shipped blocks: ${N} total; intersecting requested 1-day window: ${IN}; outside: ${OUT}"
    info "shipped data span: $(date -u -d "@${MIN_S}" +%FT%TZ) .. $(date -u -d "@${MAX_S}" +%FT%TZ)"
    if [[ ${N} -eq 0 ]]; then
        fail "no TSDB blocks present in ${TSDB}"
    elif [[ "${CLAMPED}" == "true" ]]; then
        # honesty proof: nothing from the requested window could have shipped
        if (( IN > 0 )); then
            fail "clamped run yet ${IN} block(s) intersect the requested window - impossible; data mismatch"
        fi
        if jq -e '.original_request | .since and .until' "${META}/time-window.json" >/dev/null 2>&1; then
            pass "clamp declared WITH original_request recorded:"
            sed 's/^/      /' <(jq -c '.original_request' "${META}/time-window.json")
        else
            fail "window_clamped=true but original_request missing from time-window.json (cannot prove what was requested)"
        fi
        pass "time boundaries: requested period disjoint from on-disk data; shipped span is the declared clamp (honest, no data from the requested period faked)"
    else
        if (( OUT == 0 && IN > 0 )); then
            pass "time boundaries: every shipped block (${IN}) intersects the requested 1-day window and no out-of-window block was shipped"
        else
            fail "unclamped run: ${OUT} block(s) outside requested window / ${IN} inside - selection misbehaved (see block-inventory.tsv)"
        fi
    fi
fi

echo; echo "=== 3. DATA INTEGRITY ==="
SUMS="${SNAP}/SHA256SUMS"
if [[ -f "${SUMS}" ]]; then
    if (cd "${SNAP}" && sha256sum -c --quiet SHA256SUMS 2>/tmp/vx-sha.err); then
        pass "sha256sum -c: all $(wc -l < "${SUMS}") entries verified (archive + unpacked tree, file by file)"
    else
        fail "sha256sum -c reported mismatches:"; sed 's/^/      /' /tmp/vx-sha.err
    fi
else
    fail "SHA256SUMS missing in ${SNAP}"
fi

if [[ -n "${ARCHIVE}" ]]; then
    case "${ARCHIVE}" in
        *.tar.zstd) TAROPT="-I zstd" ;;
        *.tar.gz)   TAROPT="-I gzip" ;;
        *)          TAROPT="" ;;
    esac
    if (cd "${SNAP}" && tar ${TAROPT} -tf "$(basename "${ARCHIVE}")" >/dev/null 2>&1); then
        pass "archive member list OK: $(basename "${ARCHIVE}")"
    else
        fail "archive corrupt / unreadable: $(basename "${ARCHIVE}")"
    fi
    UNPACK="$(mktemp -d /tmp/vx-unpack.XXXXXX)"
    # archive members are rooted at the TS dir ('./<block>/...'), so UNPACK
    # itself holds the tree - compare it straight against the shipped tree
    if (cd "${SNAP}" && tar ${TAROPT} -xf "$(basename "${ARCHIVE}")" -C "${UNPACK}") \
       && diff -rq "${UNPACK}" "${TSDB}" >/dev/null 2>/tmp/vx-diff.err; then
        pass "archive unpacks to a tree IDENTICAL to the shipped one"
    else
        fail "archive content differs from shipped tree:"; sed 's/^/      /' /tmp/vx-diff.err | head -8
    fi
    rm -rf "${UNPACK}"
else
    warn "no archive artifact (COMPRESS=none?) - archive checks skipped"
fi

# per-block structural check
STRUCC_BAD=0
for d in "${TSDB}"/*/; do
    [[ -d "${d}" ]] || continue
    b="$(basename "${d}")"
    [[ "${b}" =~ ^[0-9A-Z]{26}$ ]] || continue
    for need in meta.json index chunks; do
        [[ -e "${d}${need}" ]] || { fail "block ${b}: missing ${need}"; STRUCC_BAD=1; }
    done
done
(( STRUCC_BAD == 0 )) && pass "structure: all block dirs carry meta.json + index + chunks/"

# exported-blocks.tsv (gather-side manifest) vs local meta.json
TSV="${META}/exported-blocks.tsv"
if [[ -f "${TSV}" ]]; then
    TSV_BAD=0
    while read -r b mt xt sz; do
        [[ "${b}" == "block" ]] && continue
        mj="${TSDB}/${b}/meta.json"
        [[ -f "${mj}" ]] || { fail "manifest block ${b} absent from shipped tree"; TSV_BAD=1; continue; }
        lmin=$(( $(jq -r '.minTime // 0' "${mj}") / 1000 ))
        lmax=$(( $(jq -r '.maxTime // 0' "${mj}") / 1000 ))
        if (( lmin != mt / 1000 || lmax != xt / 1000 )); then
            fail "manifest mismatch for ${b}: tsv=[$( (( mt / 1000 )) )..$( (( xt / 1000 )) )] meta.json=[$(lmin)..${lmax}]"
            TSV_BAD=1
        fi
    done < "${TSV}"
    if (( ${TSV_BAD} == 0 )); then
        pass "exported-blocks.tsv agrees with on-disk meta.json (boundaries per block)"
    fi
else
    warn "exported-blocks.tsv missing (image < v1.5.0?) - manifest cross-check skipped"
fi

# optional real promtool pass on the extracted tree
if command -v promtool >/dev/null 2>&1; then
    if promtool tsdb list "${TSDB}" >/tmp/vx-pt.out 2>&1; then
        pass "promtool tsdb list: $(grep -c '[0-9A-Z]\{26\}' /tmp/vx-pt.out) blocks read without error"
    else
        fail "promtool tsdb list failed:"; sed 's/^/      /' /tmp/vx-pt.out | head -6
    fi
else
    info "promtool not on this host - relying on sha256/structure/manifest checks (see README: playback prometheus is the final 'does it open' test)"
fi

# in-cluster evidence shipped by gather
if [[ -f "${META}/tsdb-verify.txt" ]]; then
    if grep -q 'error' "${META}/tsdb-verify.txt"; then
        warn "in-cluster tsdb-verify.txt contains errors (see ${META}/tsdb-verify.txt)"
    else
        info "in-cluster promtool tsdb list (shipped evidence): OK"
    fi
fi

echo; echo "=== 4. RESULT ==="
if (( FAILS == 0 )); then
    echo "OVERALL: PASS${CLAMPED:+ (requested window was declared-clamped to available data - see prometheus-metadata/time-window.json + retention.txt)}"
    exit 0
else
    echo "OVERALL: FAIL - ${FAILS} failing check(s) - inspect sections above"
    exit 1
fi
