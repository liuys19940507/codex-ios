#!/bin/bash
set -euo pipefail
mkdir -p build
xcodebuild -version
xcodegen generate --spec ios/project.yml
source scripts/ci/prepare-swift-packages.sh
simulator_id=''
cleanup() {
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id"
  fi
}
trap cleanup EXIT
simulator_id="$(python3 <<'PY'
import json, subprocess
data=json.loads(subprocess.check_output(['xcrun','simctl','list','--json']))
def version(s): return tuple(int(x) for x in s.split('.'))
sdk=version(subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip())
runtimes=[r for r in data['runtimes'] if '.iOS-' in r['identifier'] and r.get('isAvailable') and version(r['version'])<=sdk]
runtime=max(runtimes,key=lambda r:version(r['version']))
v=version(runtime['version'])+(0,0)
encoded=(v[0]<<16)+(v[1]<<8)+v[2]
types=[d for d in data['devicetypes'] if d.get('productFamily')=='iPhone' and d.get('minRuntimeVersion',0)<=encoded<=d.get('maxRuntimeVersion',2**32-1)]
device=next((d for d in types if d['name']=='iPhone 16'),types[0])
print(subprocess.check_output(['xcrun','simctl','create','CodexRemote-CI',device['identifier'],runtime['identifier']],text=True).strip())
PY
)"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
test_arguments=(-scheme CodexRemote)
if [[ -n "${CODEX_IOS_ONLY_TESTING:-}" ]]; then
  test_arguments+=("-only-testing:$CODEX_IOS_ONLY_TESTING")
fi
xcodebuild test -project ios/CodexRemote.xcodeproj "${test_arguments[@]}" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath build/CodexRemote.xcresult "${swift_package_arguments[@]}" CODE_SIGNING_ALLOWED=NO
