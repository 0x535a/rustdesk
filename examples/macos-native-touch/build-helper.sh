#!/bin/sh
set -eu
touch_example_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
touch_destination=$1
touch_arch=${2:-$(uname -m)}
case "$touch_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $touch_arch" >&2; exit 1;; esac
touch_output_dir="$touch_example_dir/.build/host-helper-$touch_arch"
touch_sdk=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$touch_output_dir" "$(dirname -- "$touch_destination")"
xcrun swiftc -O -parse-as-library -target "$touch_arch-apple-macos15.0" -sdk "$touch_sdk" \
    -module-name TouchFormat -emit-module -emit-module-path "$touch_output_dir/TouchFormat.swiftmodule" \
    -emit-object "$touch_example_dir/Sources/TouchFormat/NativeTouch.swift" -o "$touch_output_dir/TouchFormat.o"
xcrun swiftc -O -parse-as-library -target "$touch_arch-apple-macos15.0" -sdk "$touch_sdk" -I "$touch_output_dir" \
    "$touch_example_dir/Sources/TouchInjector/TouchDevice.swift" \
    "$touch_example_dir/Sources/TouchInjector/TouchInjector.swift" "$touch_output_dir/TouchFormat.o" \
    -o "$touch_output_dir/TouchInjector"
cp "$touch_output_dir/TouchInjector" "$touch_destination"
codesign --force --sign "${RUSTDESK_NATIVE_TOUCH_SIGN_IDENTITY:--}" \
    --entitlements "$touch_example_dir/TouchInjector.entitlements" "$touch_destination"
codesign --verify --strict "$touch_destination"
