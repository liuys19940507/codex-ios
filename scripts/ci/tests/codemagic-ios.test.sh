#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/scripts/ci"
cat > "$fixture/bin/git" <<'SH'
#!/bin/bash
printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SH
cat > "$fixture/bin/xcrun" <<'SH'
#!/bin/bash
if [[ ${EXPORT_STATUS:-0} != 0 ]]; then exit "$EXPORT_STATUS"; fi
mkdir -p build/ios-screenshots
printf '[]\n' > build/ios-screenshots/manifest.json
SH
cat > "$fixture/bin/ditto" <<'SH'
#!/bin/bash
for last; do :; done
touch "$last"
SH
cat > "$fixture/scripts/ci/test-ios.sh" <<'SH'
#!/bin/bash
if [[ ${HAS_RESULT:-1} == 1 ]]; then mkdir -p build/CodexRemote.xcresult; fi
exit "${TEST_STATUS:-0}"
SH
cat > "$fixture/scripts/ci/verify-ios-tests.sh" <<'SH'
#!/bin/bash
test -d build/CodexRemote.xcresult || exit 1
printf '{"passedTests":78,"failedTests":0,"result":"Passed"}\n' > build/ios-test-summary.json
exit "${SUMMARY_STATUS:-0}"
SH
cat > "$fixture/scripts/ci/package-ios.sh" <<'SH'
#!/bin/bash
touch build/packaging-started build/CodexRemote-unsigned.ipa
SH
chmod +x "$fixture/bin/"*
run_case() {
    local name="$1" expected="$2" should_package="$3" retain_result="$4"
    shift 4
    rm -rf "$fixture/build"
    local actual=0
    (cd "$fixture" && env PATH="$fixture/bin:$PATH" TEST_STATUS=0 SUMMARY_STATUS=0 EXPORT_STATUS=0 HAS_RESULT=1 "$@" bash "$repo/scripts/ci/codemagic-ios.sh") > "$fixture/case.log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$fixture/case.log" >&2
        echo "FAIL $name: expected exit $expected, got $actual" >&2
        exit 1
    fi
    if [[ "$should_package" == yes ]]; then test -f "$fixture/build/packaging-started"
    else test ! -e "$fixture/build/packaging-started"; fi
    if [[ "$retain_result" == yes ]]; then test -f "$fixture/build/CodexRemote-tests.zip"; fi
    test -f "$fixture/build/commit.txt"
    printf 'PASS %s\n' "$name"
}
run_case test_failure 65 no yes TEST_STATUS=65
run_case missing_result 1 no no HAS_RESULT=0
run_case invalid_summary 1 no yes SUMMARY_STATUS=1
run_case export_failure 9 no yes EXPORT_STATUS=9
run_case passing_tests_package 0 yes yes
