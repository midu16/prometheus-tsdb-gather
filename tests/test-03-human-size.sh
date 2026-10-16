#!/usr/bin/bash
# =============================================================================
# test-03-human-size.sh -- unit matrix for human_size_to_bytes
# (extracted verbatim from gather, so the shipped code is what runs)
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

section "test-03: human_size_to_bytes"
extract_func human_size_to_bytes || exit 1

check() {
    local in="$1" want="$2" got
    got="$(human_size_to_bytes "${in}")"
    if [[ "${got}" == "${want}" ]]; then
        pass "'${in:-<empty>}' -> ${got}"
    else
        fail "'${in:-<empty>}' -> '${got}' (want '${want}')"
    fi
}

section "test-03: plain bytes"
check "0"          0
check "512"        512
check "4294967296" 4294967296
check "1073741824" 1073741824

section "test-03: KB/MB/GB/TB (uppercase, the --limit spellings)"
check "1K"         1024
check "4KB"        4096
check "100Mb"      104857600
check "500MB"      524288000
check "4GB"        4294967296
check "1234GB"     1324997410816
check "1T"         1099511627776
check "2TB"        2199023255552

section "test-03: binary units (KiB/MiB/GiB/TiB) + single-letter"
check "1KiB"       1024
check "512Mi"      536870912
check "2Gi"        2147483648
check "3Ti"        3298534883328
check "1G"         1073741824
check "2M"         2097152

section "test-03: disables / invalid"
check "none"       none
check "NONE"       none
check "off"        none
check "unlimited"  none
check "disabled"   none
check ""           none
check "junk"       ""
check "12XB"       ""
check "1.5G"       ""
check "-5"         ""

finish "test-03-human-size"
