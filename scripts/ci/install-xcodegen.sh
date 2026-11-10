#!/bin/bash
set -euo pipefail
tool_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
archive="$tool_root/xcodegen-2.46.0.zip"
curl --fail --location --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 20 --max-time 120 'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip' -o "$archive"
printf '%s  %s\n' '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' "$archive" | shasum -a 256 -c -
unzip -q -o "$archive" -d "$tool_root/xcodegen-2.46.0"
tool_bin="$tool_root/xcodegen-2.46.0/xcodegen/bin"
if [[ -n ${GITHUB_PATH:-} ]]; then
    printf '%s\n' "$tool_bin" >> "$GITHUB_PATH"
elif [[ -n ${CM_ENV:-} ]]; then
    printf 'PATH=%s:%s\n' "$tool_bin" "$PATH" >> "$CM_ENV"
else
    printf 'XcodeGen installed in %s; add it to PATH before building.\n' "$tool_bin"
fi
"$tool_bin/xcodegen" --version
