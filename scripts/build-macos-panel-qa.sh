#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
package_root="$repository_root/macos"
application_path="$package_root/.build/tests/手动收起验收.app"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_interface="$(/usr/bin/find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
interface_version="$(/usr/bin/sed -n 's/.*-interface-compiler-version \([^ ]*\).*/\1/p' "$swift_interface" | /usr/bin/head -n 1)"
/bin/mkdir -p "$application_path/Contents/MacOS"
/usr/bin/xcrun swiftc -O -warnings-as-errors -swift-version 5 -D STATION_PANEL_QA \
    -target "$(/usr/bin/uname -m)-apple-macosx13.0" -sdk "$sdk_path" \
    -module-cache-path "$package_root/.build/module-cache" \
    -Xfrontend -interface-compiler-version -Xfrontend "$interface_version" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UniformTypeIdentifiers \
    "$package_root"/Sources/FloatingTransferStationMac/*.swift \
    -o "$application_path/Contents/MacOS/PanelCollapseQA"
/usr/bin/ditto "$package_root/Tests/PanelCollapseQA/Info.plist" "$application_path/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$application_path"
printf '%s\n' "$application_path"
