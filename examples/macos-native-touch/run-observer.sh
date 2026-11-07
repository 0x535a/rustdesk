#!/bin/sh
set -eu
touch_example_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
touch_output_dir="$touch_example_dir/.build/observer"
touch_app_path="$touch_example_dir/.build/TouchObserver.app"
touch_sdk=$(xcrun --sdk macosx --show-sdk-path)
touch_target="$(uname -m)-apple-macos15.0"
mkdir -p "$touch_output_dir" "$touch_app_path/Contents/MacOS"
xcrun swiftc -O -parse-as-library -target "$touch_target" -sdk "$touch_sdk" \
    -module-name TouchObserverState -emit-module \
    -emit-module-path "$touch_output_dir/TouchObserverState.swiftmodule" -emit-object \
    "$touch_example_dir/Sources/TouchObserverState/TouchObservation.swift" -o "$touch_output_dir/TouchObserverState.o"
xcrun swiftc -O -parse-as-library -target "$touch_target" -sdk "$touch_sdk" -I "$touch_output_dir" \
    "$touch_example_dir/Sources/TouchObserver/TouchObserver.swift" "$touch_output_dir/TouchObserverState.o" \
    -o "$touch_app_path/Contents/MacOS/TouchObserver"
cp "$touch_example_dir/Observer/Info.plist" "$touch_app_path/Contents/Info.plist"
codesign --force --sign - "$touch_app_path"
exec "$touch_app_path/Contents/MacOS/TouchObserver" "$@"
