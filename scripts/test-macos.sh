#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
package_root="$repository_root/macos"
test_root="$package_root/.build/tests"
module_cache="$package_root/.build/module-cache"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
architecture="$(/usr/bin/uname -m)"
swift_interface="$(/usr/bin/find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
interface_version=""
if [[ -n "$swift_interface" ]]; then
    interface_version="$(/usr/bin/sed -n 's/.*-interface-compiler-version \([^ ]*\).*/\1/p' "$swift_interface" | /usr/bin/head -n 1)"
fi

/bin/mkdir -p "$test_root" "$module_cache"
compiler_arguments=(
    -Onone
    -parse-as-library
    -swift-version 5
    -target "$architecture-apple-macosx13.0"
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
    -framework AppKit
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
    "$package_root/Sources/FloatingTransferStationMac/Models.swift" \
    "$package_root/Sources/FloatingTransferStationMac/LocalStore.swift" \
    "$package_root/Sources/FloatingTransferStationMac/BoardModel.swift" \
    "$package_root/Sources/FloatingTransferStationMac/PanelPresentation.swift" \
    "$package_root/Tests/MacCoreTests/main.swift" \
    -o "$test_root/MacCoreTests"

"$test_root/MacCoreTests"
