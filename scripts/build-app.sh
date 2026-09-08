#!/bin/zsh
set -eu
task_dir="${0:A:h}"
task_root="${task_dir:h}"
task_output="$task_root/.codex-work/memory-watch-build"
task_app="$task_output/Memory Watch.app"
mkdir -p "$task_app/Contents/MacOS" "$task_output/module-cache"
/usr/bin/swiftc -O -file-prefix-map "$task_root=." -target "$(/usr/bin/uname -m)-apple-macos13.0" -module-cache-path "$task_output/module-cache" \
  "$task_root/src/MemoryWatch.swift" -o "$task_app/Contents/MacOS/MemoryWatch" \
  -framework AppKit -framework UserNotifications
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.shuangsu.memory-watch</string>
<key>CFBundleName</key><string>Memory Watch</string>
<key>CFBundleDisplayName</key><string>内存提醒</string>
<key>CFBundleExecutable</key><string>MemoryWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A file provider can re-add FinderInfo between xattr and codesign in Documents.
# This tiny disposable signing copy is outside the synced tree; the zip is immutable.
task_sign_dir=$(/usr/bin/mktemp -d /tmp/memory-watch-sign.XXXXXX)
trap 'rm -rf -- "$task_sign_dir"' EXIT
task_signed_app="$task_sign_dir/Memory Watch.app"
/usr/bin/ditto --noextattr --norsrc "$task_app" "$task_signed_app"
/usr/bin/xattr -cr "$task_signed_app"
/usr/bin/codesign --force --sign - "$task_signed_app"
/usr/bin/codesign --verify --strict "$task_signed_app"
"$task_signed_app/Contents/MacOS/MemoryWatch" --self-test
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$task_signed_app" "$task_output/Memory Watch.zip"
print -r -- "$task_output/Memory Watch.zip"
