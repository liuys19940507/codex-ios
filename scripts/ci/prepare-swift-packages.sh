#!/bin/bash
# Sourced after XcodeGen; pin the same resolved graph in simulator and device builds.
swift_package_arguments=(-clonedSourcePackagesDirPath "$PWD/build/SourcePackages")
if [[ -f ios/Package.resolved ]]; then
  package_dir='ios/CodexRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm'
  mkdir -p "$package_dir"
  cp ios/Package.resolved "$package_dir/Package.resolved"
  swift_package_arguments+=(-onlyUsePackageVersionsFromResolvedFile)
fi
