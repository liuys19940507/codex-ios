#!/bin/bash
set -euo pipefail
archive="${RUNNER_TEMP:?}/xcodegen-2.46.0.zip"
curl --fail --location --retry 3 'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip' -o "$archive"
printf '%s  %s\n' '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' "$archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$RUNNER_TEMP/xcodegen-2.46.0"
echo "$RUNNER_TEMP/xcodegen-2.46.0/xcodegen/bin" >> "$GITHUB_PATH"
"$RUNNER_TEMP/xcodegen-2.46.0/xcodegen/bin/xcodegen" --version
