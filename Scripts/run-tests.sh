#!/bin/bash
#
# Runs the suite in groups, one group at a time.
#
# One `xcodebuild test` over 95 test classes is a single process holding a real
# window server session for twenty minutes, and the tests that wait on a window,
# an animation or a panel are the ones that give up when the Mac is busy. Groups
# keep each run short and tear the test host down in between, so a slow machine
# stays a slow machine rather than a failing one.
#
# Nothing here runs in parallel, deliberately — two `xcodebuild test`
# invocations at once fight over the same UI session, and the failures that
# produces ("expected non-nil value of type NSOpenPanel") look like real bugs.
#
#     Scripts/run-tests.sh                 # the Core package, then every group
#     Scripts/run-tests.sh -g 20           # bigger groups, fewer launches
#     Scripts/run-tests.sh -o Library      # only the classes whose name matches
#     Scripts/run-tests.sh --no-core       # skip the Core package
#
# Groups are cut from the class names as they are found, so a new test file
# needs no edit here.
set -u

cd "$(dirname "$0")/.." || exit 1

size=12
only=""
core=yes

while [ $# -gt 0 ]; do
    case "$1" in
        -g) size="$2"; shift 2 ;;
        -o) only="$2"; shift 2 ;;
        --no-core) core=no; shift ;;
        -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

derived="${DUMPCOMPARE_DD:-$PWD/.build/xcode}"
failed=0

report() {   # keeps the counts and the failures, drops the rest
    grep -E "^/Users.*error:|Executed [0-9]+ tests" | tail -20
}

if [ "$core" = yes ] && [ -z "$only" ]; then
    echo "── DumpCompareCore"
    ( cd DumpCompareCore && swift test 2>&1 ) | report | tail -1
    [ "${PIPESTATUS[0]:-0}" -ne 0 ] && failed=1
fi

classes=$(grep -h "^final class .*: XCTestCase" DumpCompareTests/*.swift \
    | sed 's/final class \([A-Za-z0-9_]*\).*/\1/' | sort)
if [ -n "$only" ]; then
    classes=$(echo "$classes" | grep -E -- "$only")
fi
[ -z "$classes" ] && { echo "no test classes matched"; exit 1; }

total=$(echo "$classes" | wc -l | tr -d ' ')
group=1
index=0
args=""
first=""
last=""

run_group() {
    [ -z "$args" ] && return
    echo "── group $group: $first … $last"
    # shellcheck disable=SC2086
    xcodebuild -project DumpCompare.xcodeproj -scheme DumpCompare \
        -derivedDataPath "$derived" -parallel-testing-enabled NO \
        $args test 2>&1 | report
    status=${PIPESTATUS[0]}
    [ "$status" -ne 0 ] && failed=1
    group=$((group + 1))
    args=""
    first=""
}

for class in $classes; do
    args="$args -only-testing:DumpCompareTests/$class"
    [ -z "$first" ] && first="$class"
    last="$class"
    index=$((index + 1))
    if [ $((index % size)) -eq 0 ]; then
        run_group
    fi
done
run_group

echo "── $total classes in $((group - 1)) group(s)"
[ "$failed" -ne 0 ] && { echo "── something failed"; exit 1; }
echo "── all green"
