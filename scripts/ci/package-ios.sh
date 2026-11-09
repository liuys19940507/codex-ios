#!/bin/bash
set -euo pipefail
mkdir -p build
xcodebuild -version
xcodegen generate --spec ios/project.yml
xcodebuild archive -project ios/CodexRemote.xcodeproj -scheme CodexRemote \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/CodexRemote.xcarchive CODE_SIGNING_ALLOWED=NO
app="$PWD/build/CodexRemote.xcarchive/Products/Applications/CodexRemote.app"
test -f "$app/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")" = 'com.liuys.codexremote'
test "$(/usr/libexec/PlistBuddy -c 'Print DTPlatformName' "$app/Info.plist")" = 'iphoneos'
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")"
lipo -verify_arch arm64 "$app/$executable"
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/codex-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/CodexRemote.app"
output="$PWD/build/CodexRemote-unsigned.ipa"
(cd "$staging" && ditto -c -k --keepParent Payload "$output")
unzip -l "$output"
unzip -Z1 "$output" | grep -Fx 'Payload/CodexRemote.app/Info.plist'
git rev-parse HEAD > build/commit.txt
shasum -a 256 "$output" > build/CodexRemote-unsigned.ipa.sha256
