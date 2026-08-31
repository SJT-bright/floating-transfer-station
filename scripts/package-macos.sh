#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
package_root="$repository_root/macos"
output_root="$repository_root/artifacts/macos"
work_root="$(/usr/bin/mktemp -d /private/tmp/floating-transfer-station-package.XXXXXX)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
swift_interface="$(/usr/bin/find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
interface_version=""

cleanup() {
    /bin/rm -rf "$work_root"
}
trap cleanup EXIT

if [[ -n "$swift_interface" ]]; then
    interface_version="$(/usr/bin/sed -n 's/.*-interface-compiler-version \([^ ]*\).*/\1/p' "$swift_interface" | /usr/bin/head -n 1)"
fi

compile_architecture() {
    local architecture="$1"
    local module_cache="$work_root/module-cache-$architecture"
    local binary_path="$work_root/FloatingTransferStationMac-$architecture"
    local compiler_arguments=(
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

    /bin/mkdir -p "$module_cache"
    if [[ -n "$interface_version" ]]; then
        compiler_arguments+=(
            -Xfrontend -interface-compiler-version
            -Xfrontend "$interface_version"
        )
    fi

    "$swift_compiler" \
        "${compiler_arguments[@]}" \
        "$package_root"/Sources/FloatingTransferStationMac/*.swift \
        -o "$binary_path"
}

compile_architecture arm64
compile_architecture x86_64

application_path="$work_root/悬浮中转站.app"
universal_binary="$application_path/Contents/MacOS/FloatingTransferStationMac"
/bin/mkdir -p "$application_path/Contents/MacOS"
/usr/bin/lipo -create \
    "$work_root/FloatingTransferStationMac-arm64" \
    "$work_root/FloatingTransferStationMac-x86_64" \
    -output "$universal_binary"
/usr/bin/ditto "$package_root/Info.plist" "$application_path/Contents/Info.plist"
/bin/chmod +x "$universal_binary"
/usr/bin/codesign --force --deep --options runtime --sign - "$application_path"

/usr/bin/codesign --verify --deep --strict "$application_path"
/usr/bin/plutil -lint "$application_path/Contents/Info.plist"

share_folder="$work_root/悬浮中转站-macOS"
/bin/mkdir -p "$share_folder"
/usr/bin/ditto "$application_path" "$share_folder/悬浮中转站.app"
/usr/bin/ditto "$package_root/使用说明.txt" "$share_folder/使用说明.txt"
/usr/bin/ditto "$repository_root/LICENSE" "$share_folder/LICENSE"

/bin/mkdir -p "$output_root"
application_archive="$output_root/FloatingTransferStation-macOS-universal.zip"
source_archive="$output_root/FloatingTransferStation-source.zip"
/bin/rm -f "$application_archive" "$source_archive"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$share_folder" "$application_archive"

source_folder="$work_root/floating-transfer-station-source"
/usr/bin/rsync -a \
    --exclude='.git/' \
    --exclude='.DS_Store' \
    --exclude='.superpowers/' \
    --exclude='.tools/' \
    --exclude='.vs/' \
    --exclude='.worktrees/' \
    --exclude='artifacts/' \
    --exclude='TestResults/' \
    --exclude='bin/' \
    --exclude='obj/' \
    --exclude='macos/.build/' \
    "$repository_root/" "$source_folder/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$source_folder" "$source_archive"

echo "$application_archive"
echo "$source_archive"
