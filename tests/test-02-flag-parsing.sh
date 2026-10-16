#!/usr/bin/bash
# =============================================================================
# test-02-flag-parsing.sh -- every flag, valid + invalid, incl. the env forms
#
# Runs the REAL gather script offline-safe (see run_gather in helpers.sh):
# rejections are exit 64 with a stable message, before any cluster access;
# acceptances prove the combo survives flag-validation and only stops at
# pre-flight (bogus pod / no cluster) - never at the parser.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-02: general flag handling"
run_gather --frobnicate;                assert_flag_rejected "unknown flag --frobnicate" "unknown flag"
run_gather --limit;                     assert_flag_rejected "--limit without value" "--limit needs a value"
run_gather --max-size;                  assert_flag_rejected "--max-size without value" "--max-size needs a value"
run_gather --since;                     assert_flag_rejected "--since without value" "--since needs a value"
run_gather --until;                     assert_flag_rejected "--until without value" "--until needs a value"
run_gather --include-wal;               assert_flag_rejected "--include-wal without value" "--include-wal needs a value"
run_gather --compress;                  assert_flag_rejected "--compress without value" "--compress needs a value"
run_gather --max-gb;                    assert_flag_rejected "--max-gb without value" "--max-gb needs a value"
run_gather --at;                        assert_flag_rejected "--at without value" "--at needs a value"

section "test-02: --limit (v1.6.0)"
run_gather --limit junk;                assert_flag_rejected "--limit junk" "cannot parse --limit"
run_gather --limit 12XB;                assert_flag_rejected "--limit 12XB" "cannot parse --limit"
GATHER_LIMIT_POLL=abc run_gather;       assert_flag_rejected "GATHER_LIMIT_POLL=abc" "GATHER_LIMIT_POLL must be"
GATHER_LIMIT_POLL=0 run_gather;         assert_flag_rejected "GATHER_LIMIT_POLL=0" "GATHER_LIMIT_POLL must be"
for v in 4GB 500MB 1234GB 4294967296 0 none off unlimited 10Mi 1Ti 1073741824; do
    run_gather --limit "${v}";          assert_flag_accepted "--limit ${v}"
done
GATHER_LIMIT=4GB run_gather;            assert_flag_accepted "env GATHER_LIMIT=4GB"
GATHER_LIMIT=0 run_gather;              assert_flag_accepted "env GATHER_LIMIT=0 (unlimited)"

section "test-02: --max-size / --size-policy"
run_gather --max-size junk;             assert_flag_rejected "--max-size junk" "cannot parse --max-size"
for v in 2Gi 512Mi 500MB 1073741824 none off; do
    run_gather --max-size "${v}";       assert_flag_accepted "--max-size ${v}"
done
run_gather --size-policy bogus;         assert_flag_rejected "--size-policy bogus" "must be 'fail' or 'warn'"
for v in fail warn; do
    run_gather --size-policy "${v}";    assert_flag_accepted "--size-policy ${v}"
done

section "test-02: --since / --until (window logic untouched)"
run_gather --since abc;                 assert_flag_rejected "--since abc" "cannot parse --since"
run_gather --until abc;                 assert_flag_rejected "--until abc" "cannot parse --until"
run_gather --since 2026-10-16T00:00:00Z --until 2026-10-15T00:00:00Z
                                        assert_flag_rejected "--since after --until" "is after --until"
for combo in \
    "--since 30d --until 29d" \
    "--since 6h --until now" \
    "--since 3d12h --until 12s" \
    "--since 2026-09-29T10:00:00Z --until 2026-09-30T00:00:00Z" \
    "--since '24 hours ago' --until '2 hours ago'" \
    "--since 1727000000 --until 1727100000"; do
    eval "run_gather ${combo}";         assert_flag_accepted "window ${combo//\"/}"
done
SINCE=30d UNTIL=29d run_gather;         assert_flag_accepted "env SINCE/UNTIL"

section "test-02: --include-wal / --compress"
run_gather --include-wal maybe;         assert_flag_rejected "--include-wal maybe" "must be true|false|auto"
for v in true false auto; do
    run_gather --include-wal "${v}";    assert_flag_accepted "--include-wal ${v}"
done
run_gather --compress bzip2;            assert_flag_rejected "--compress bzip2" "must be none|zstd|gzip"
for v in none zstd gzip; do
    run_gather --compress "${v}";       assert_flag_accepted "--compress ${v}"
done

section "test-02: legacy --max-gb / --at / --strict-notready"
run_gather --max-gb 0;                  assert_flag_rejected "--max-gb 0" "must be a positive integer"
run_gather --max-gb abc;                assert_flag_rejected "--max-gb abc" "must be a positive integer"
for v in 1 5 100; do
    run_gather --max-gb "${v}";         assert_flag_accepted "--max-gb ${v}"
done
run_gather --at 'not a date';           assert_flag_rejected "--at 'not a date'" "cannot parse --at"
run_gather --at '2 days ago';           assert_flag_accepted "--at '2 days ago'"
run_gather --strict-notready true;      assert_flag_rejected "--strict-notready with extra 'true' (not a value flag)" "unknown flag"
STRICT_NOTREADY=maybe run_gather;       assert_flag_rejected "STRICT_NOTREADY=maybe" "must be 'true' if set"
run_gather --strict-notready;           assert_flag_accepted "--strict-notready"
STRICT_NOTREADY=true run_gather;        assert_flag_accepted "STRICT_NOTREADY=true"

section "test-02: the operator's production invocations"
run_gather --since 30d --until 29d --limit 1234GB
    assert_flag_accepted "production: --since 30d --until 29d --limit 1234GB"
run_gather --since 30d --until 29d --limit 0
    assert_flag_accepted "production: --since 30d --until 29d --limit 0"
run_gather --max-size none --limit 0 --compress zstd --include-wal auto --size-policy warn --max-gb 5 --strict-notready
    assert_flag_accepted "kitchen-sink combo (all flags at once)"
MAX_GATHER_BYTES=none SIZE_POLICY=warn GATHER_LIMIT=0 COMPRESS=gzip INCLUDE_WAL=false GATHER_TSDB_MAX_GB=5 SINCE=30d UNTIL=29d run_gather
    assert_flag_accepted "all-env-vars form (wrapper style)"

finish "test-02-flag-parsing"
