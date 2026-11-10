#!/bin/bash
set -euo pipefail
mkdir -p build/approval-diagnostics
git rev-parse HEAD > build/commit.txt
test_filter="${1:-CodexRemoteUITests/ThreadUITests/testCommandApprovalIsActionableWithProcessCollapsedAboveComposer}"
monitor_pid=''
if [[ "$test_filter" == CodexRemoteUITests/ThreadUITests/testCommandApprovalIsActionableWithProcessCollapsedAboveComposer ]]; then
    python3 scripts/ci/sample-approval.py build/approval-diagnostics > build/approval-diagnostics/sampler.log 2>&1 &
    monitor_pid=$!
fi
cleanup() {
    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" >/dev/null 2>&1 || true
        wait "$monitor_pid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
test_status=0
CODEX_IOS_ONLY_TESTING="$test_filter" \
    bash scripts/ci/test-ios.sh 2>&1 | tee build/ios-test.log || test_status=$?
cleanup
trap - EXIT
if [[ -n "$monitor_pid" ]]; then
    ditto -c -k --keepParent build/approval-diagnostics build/approval-diagnostics.zip
fi
summary_status=0
bash scripts/ci/verify-ios-tests.sh || summary_status=$?
if [[ -d build/CodexRemote.xcresult ]]; then
    xcrun xcresulttool export attachments --path build/CodexRemote.xcresult --output-path build/ios-screenshots
    ditto -c -k --keepParent build/ios-screenshots build/ios-screenshots.zip
fi
if [[ "$test_status" != 0 ]]; then exit "$test_status"; fi
exit "$summary_status"
