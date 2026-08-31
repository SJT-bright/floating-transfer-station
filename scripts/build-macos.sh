#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
package_root="$repository_root/macos"
build_root="$package_root/.build/release"
application_path="$build_root/悬浮中转站.app"
module_cache="$package_root/.build/module-cache"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
architecture="$(/usr/bin/uname -m)"
swift_interface="$(/usr/bin/find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
interface_version=""
if [[ -n "$swift_interface" ]]; then
    interface_version="$(/usr/bin/sed -n 's/.*-interface-compiler-version \([^ ]*\).*/\1/p' "$swift_interface" | /usr/bin/head -n 1)"
fi

/bin/mkdir -p "$build_root" "$module_cache"
compiler_arguments=(
    -O
    -swift-version 5
    -target "$architecture-apple-macosx13.0"
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
    -framework AppKit
    -framework ServiceManagement
    -framework SwiftUI
    -framework UniformTypeIdentifiers
)
if [[ -n "$interface_version" ]]; then
    compiler_arguments+=(
        -Xfrontend -interface-compiler-version
        -Xfrontend "$interface_version"
    )
fi

"$swift_compiler" \
    "${compiler_arguments[@]}" \
    "$package_root"/Sources/FloatingTransferStationMac/*.swift \
    -o "$build_root/FloatingTransferStationMac"

if [[ -d "$application_path" ]]; then
    /bin/rm -rf "$application_path"
fi
/bin/mkdir -p "$application_path/Contents/MacOS"
/usr/bin/ditto "$build_root/FloatingTransferStationMac" "$application_path/Contents/MacOS/FloatingTransferStationMac"
/usr/bin/ditto "$package_root/Info.plist" "$application_path/Contents/Info.plist"
/bin/chmod +x "$application_path/Contents/MacOS/FloatingTransferStationMac"
/usr/bin/codesign --force --deep --sign - "$application_path"

echo "$application_path"
