#!/bin/bash
set -euo pipefail
mkdir -p build/approval-diagnostics
git rev-parse HEAD > build/commit.txt
python3 scripts/ci/sample-approval.py build/approval-diagnostics > build/approval-diagnostics/sampler.log 2>&1 &
monitor_pid=$!
cleanup() {
    kill "$monitor_pid" >/dev/null 2>&1 || true
    wait "$monitor_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT
test_status=0
CODEX_IOS_ONLY_TESTING=CodexRemoteUITests/ThreadUITests/testCommandApprovalIsActionableWithProcessCollapsedAboveComposer \
    bash scripts/ci/test-ios.sh 2>&1 | tee build/ios-test.log || test_status=$?
cleanup
trap - EXIT
ditto -c -k --keepParent build/approval-diagnostics build/approval-diagnostics.zip
if [[ -d build/CodexRemote.xcresult ]]; then
    xcrun xcresulttool export attachments --path build/CodexRemote.xcresult --output-path build/ios-screenshots
    ditto -c -k --keepParent build/ios-screenshots build/ios-screenshots.zip
fi
exit "$test_status"
