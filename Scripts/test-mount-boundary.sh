#!/bin/bash
# Invoked by test-scanner.sh --mount-boundary after the fixture runner has compiled.
set -euo pipefail
[[ $# -eq 1 && -x "$1" ]] || { echo "Use Scripts/test-scanner.sh --mount-boundary" >&2; exit 2; }
runner="$1"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/storage-mount-check.XXXXXXXX")"
scan_root="$fixture/scan"
mount_point="$scan_root/mounted"
image="$fixture/volume.sparseimage"
volume_name="MSI-$(uuidgen)"

cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ -d "$mount_point" ]]; then
        local parent_device mounted_device mounted_name
        parent_device="$(stat -f '%d' "$scan_root")" || exit 1
        mounted_device="$(stat -f '%d' "$mount_point")" || exit 1
        if [[ "$parent_device" != "$mounted_device" ]]; then
            mounted_name="$(diskutil info -plist "$mount_point" | plutil -extract VolumeName raw -)" || {
                echo "Cannot identify the mounted volume. Preserving $fixture." >&2
                exit 1
            }
            if [[ "$mounted_name" != "$volume_name" ]]; then
                echo "Volume identity changed. Preserving $fixture." >&2
                exit 1
            fi
            if ! hdiutil detach "$mount_point"; then
                echo "Image is busy. Preserving the fixture at $fixture." >&2
                exit 1
            fi
        fi
        if [[ -d "$mount_point" ]]; then
            [[ "$(stat -f '%d' "$mount_point")" == "$parent_device" ]] || exit 1
            rmdir "$mount_point" || exit 1
        fi
    fi
    # Only remove the known fixture files, once the mount point is gone.
    rm -f "$scan_root/local-file" "$image"
    if [[ -d "$scan_root" ]]; then rmdir "$scan_root"; fi
    rmdir "$fixture"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$mount_point"
printf 'local' > "$scan_root/local-file"
hdiutil create -size 64m -type SPARSE -fs APFS -nospotlight -volname "$volume_name" "$image"
hdiutil attach -mount required -mountpoint "$mount_point" -nobrowse -noautoopen "$image"
[[ "$(stat -f '%d' "$mount_point")" != "$(stat -f '%d' "$scan_root")" ]]
[[ "$(diskutil info -plist "$mount_point" | plutil -extract VolumeName raw -)" == "$volume_name" ]]
printf 'only on the disk image' > "$mount_point/image-file"
"$runner" --mounted-fixture "$scan_root"
