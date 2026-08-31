#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"

"$script_dir/build-macos.sh"
/usr/bin/open "$repository_root/macos/.build/release/悬浮中转站.app"
