#!/bin/bash
# Build a locally runnable, ad-hoc signed app with the system Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

build=(swift build --configuration release)
if [[ "$#" -eq 1 && "$1" == "--universal" ]]; then
    build+=(--arch arm64 --arch x86_64)
elif [[ "$#" -ne 0 ]]; then
    echo "Usage: $0 [--universal]" >&2
    exit 2
fi

"${build[@]}" --product MacStorageIntelligence
binary_dir=$("${build[@]}" --show-bin-path)
binary="$binary_dir/MacStorageIntelligence"
if [[ "$#" -eq 1 ]]; then
    architectures=" $(lipo -archs "$binary") "
    for required in arm64 x86_64; do
        [[ "$architectures" == *" $required "* ]] || { echo "Missing $required slice" >&2; exit 1; }
    done
fi

app="$PWD/.build/Mac Storage Intelligence.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
install -m 644 Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install -m 755 "$binary" "$app/Contents/MacOS/MacStorageIntelligence"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
echo "$app"
