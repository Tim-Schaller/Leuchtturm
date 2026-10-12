#!/bin/zsh
# Archives the iPhone app (with widgets and watch app) and the Apple TV app
# and uploads both to App Store Connect for TestFlight.
#
# Needs: the app in App Store Connect (bundle ID de.timschaller.leuchtturm,
# iOS and tvOS), Xcode signed in with an account of team TW877YHM7Q, and the
# CloudKit schema deployed to Production.
#
# Usage: scripts/testflight.sh [ios|tv]   (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(date -u +%Y%m%d%H%M)
xcodegen generate
upload() {
  local scheme=$1 platform=$2
  local archive="build/Archives/$scheme-$BUILD.xcarchive"
  xcodebuild archive -project Leuchtturm.xcodeproj -scheme "$scheme" -configuration Release \
    -destination "generic/platform=$platform" -archivePath "$archive" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "build/Export/$scheme-$BUILD" -allowProvisioningUpdates
  echo "Uploaded $scheme build $BUILD"
}
case "${1:-both}" in
  ios) upload Leuchtturm iOS ;;
  tv) upload "Leuchtturm TV" tvOS ;;
  both) upload Leuchtturm iOS; upload "Leuchtturm TV" tvOS ;;
  *) echo "usage: $0 [ios|tv]"; exit 2 ;;
esac
