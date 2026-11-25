#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/wechat-relay-build.XXXXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_dir/Info.plist")"
distribution="$build_dir/distribution"
app="$distribution/群聊同步助手 $version.app"
binary="$app/Contents/MacOS/GroupRelay"
sources=(
    "$project_dir/Bridge.swift"
    "$project_dir/Desktop.swift"
    "$project_dir/Rules.swift"
    "$project_dir/SelfTest.swift"
    "$project_dir/main.swift"
)

mkdir -p "$app/Contents/MacOS"
for arch in arm64 x86_64; do
    xcrun swiftc -O -target "$arch-apple-macosx14.0" "${sources[@]}" -o "$build_dir/GroupRelay-$arch"
done
xcrun lipo -create "$build_dir/GroupRelay-arm64" "$build_dir/GroupRelay-x86_64" -output "$binary"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/README.md" "$distribution/使用说明.md"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$binary" --self-test

archive="$output_dir/WeChat-Group-Relay-Mac-$version.zip"
ditto -c -k "$distribution" "$build_dir/assistant.zip"
mv -f "$build_dir/assistant.zip" "$archive"
printf '%s\n' "$archive"
