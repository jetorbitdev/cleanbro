#!/bin/zsh
# UI smoke test for a running CleanBro, driven through the accessibility tree with axdrv
# (https://github.com/widnyana/justforfun/blob/main/swift/axdrv.md).
#
#   swiftc -O axdrv.swift -o /tmp/axdrv
#   AXDRV=/tmp/axdrv scripts/smoke-test.sh [pid]
#
# The calling app (Terminal, VS Code, ...) needs Accessibility permission.
# Read-only: it scans and toggles checkboxes, but never presses Clean, Delete or Empty Trash.
set -uo pipefail

A="${AXDRV:-axdrv}"
command -v "$A" >/dev/null || { echo "axdrv not found; set AXDRV=/path/to/axdrv"; exit 2; }

P="${1:-$("$A" apps | awk -F'\t' '$3=="CleanBro"{print $1; exit}')}"
[[ -n "$P" ]] || { echo "CleanBro is not running"; exit 4; }

fails=0
pass() { print "ok   $1"; }
fail() { print "FAIL $1"; fails=$((fails + 1)); }
nap() { perl -e "select(undef,undef,undef,$1)"; }
# `dump <selector>` exits 0 even with no match, so check the output instead.
find_el() { "$A" --pid "$P" dump "$@" 2>/dev/null; }
wait_for() {
    local secs=$1; shift
    for _ in $(seq 1 "$secs"); do
        [[ -n "$(find_el "$@")" ]] && return 0
        nap 1
    done
    return 1
}

# 1. Every sidebar page opens.
for t in home clean apps brew usage large stale dupes; do
    if "$A" --pid "$P" press "id=sidebar.$t" >/dev/null 2>&1; then pass "open sidebar.$t"
    else fail "open sidebar.$t"; fi
    nap 0.5
done

# 2. Junk scan finishes and offers a Clean button.
"$A" --pid "$P" press id=sidebar.clean >/dev/null
if [[ -n "$(find_el id=junk.scan)" ]]; then
    "$A" --pid "$P" press id=junk.scan >/dev/null
elif [[ -n "$(find_el id=junk.rescan)" ]]; then
    "$A" --pid "$P" press id=junk.rescan >/dev/null
fi
if wait_for 180 id=junk.clean; then pass "junk scan finished"
else fail "junk scan finished"; print "$fails failure(s)"; exit 1; fi

# 3. Clean is disabled with nothing checked, and comes back when re-checked.
cats=(${(f)"$(find_el role=AXCheckBox enabled=true | grep -oE 'id=junk\.category\.[a-z]+')"})
# axdrv does not print a checkbox's numeric value, so this relies on a fresh scan
# checking every category, and flips each one twice.
toggle_all() {
    for c in $cats; do "$A" --pid "$P" press "$c" >/dev/null; done
    nap 0.5
}
if (( ${#cats} == 0 )); then
    print "skip clean-button check: no selectable category"
else
    toggle_all
    if find_el id=junk.clean | grep -q "enabled=false"; then pass "clean disabled when nothing is checked"
    else fail "clean disabled when nothing is checked"; fi
    toggle_all
    if find_el id=junk.clean | grep -q "enabled=true"; then pass "clean enabled after re-checking"
    else fail "clean enabled after re-checking"; fi
fi

(( fails == 0 )) && print "all passed" || print "$fails failure(s)"
exit $(( fails > 0 ))
