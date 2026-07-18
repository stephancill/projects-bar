#!/usr/bin/env bash
set -euo pipefail

swift build -c release

app_dir=".build/ProjectsBar.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

rm -rf "$app_dir"
mkdir -p "$macos_dir"

cp Resources/Info.plist "$contents_dir/Info.plist"
cp .build/release/ProjectsBar "$macos_dir/ProjectsBar"

codesign --force --deep --sign - "$app_dir"

echo "Built $app_dir"
