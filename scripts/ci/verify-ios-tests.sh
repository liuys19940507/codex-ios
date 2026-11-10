#!/bin/bash
set -euo pipefail
test -d build/CodexRemote.xcresult
xcrun xcresulttool get test-results summary --path build/CodexRemote.xcresult > build/ios-test-summary.json
python3 - <<'PY'
import json
with open('build/ios-test-summary.json') as file:
    report = json.load(file)
assert report['passedTests'] > 0, 'No passing iOS tests were recorded'
assert report['failedTests'] == 0, report
assert report['result'] == 'Passed', report
print(f"Verified {report['passedTests']} passing iOS tests in xcresult")
PY
