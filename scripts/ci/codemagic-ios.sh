#!/bin/bash
set -euo pipefail
mkdir -p build
git rev-parse HEAD > build/commit.txt
if [[ -n "${CODEX_IOS_ONLY_TESTING:-}" ]]; then
    echo 'Filtered diagnostic tests cannot produce a release package.' >&2
    exit 2
fi

test_status=0
bash scripts/ci/test-ios.sh 2>&1 | tee build/ios-test.log || test_status=$?
summary_status=0
bash scripts/ci/verify-ios-tests.sh || summary_status=$?

# Keep diagnosis even when xcodebuild reports a failure. Neither a zero
# process exit nor a previous package is sufficient to pass the test gate.
export_status=0
if [[ -d build/CodexRemote.xcresult ]]; then
    ditto -c -k --keepParent build/CodexRemote.xcresult build/CodexRemote-tests.zip
    xcrun xcresulttool export attachments --path build/CodexRemote.xcresult --output-path build/ios-screenshots || export_status=$?
    if [[ -d build/ios-screenshots ]]; then
        ditto -c -k --keepParent build/ios-screenshots build/ios-screenshots.zip
    fi
fi
if [[ "$test_status" != 0 ]]; then exit "$test_status"; fi
if [[ "$summary_status" != 0 ]]; then exit "$summary_status"; fi
if [[ "$export_status" != 0 ]]; then exit "$export_status"; fi
bash scripts/ci/package-ios.sh 2>&1 | tee build/ios-package.log
