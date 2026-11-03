#!/bin/bash
# Builds Hootnote.app and installs it in /Applications.
#   scripts/build_app.sh             build + install
#   scripts/build_app.sh --no-install
# Icons are drawn by scripts/make_icon.swift; regenerate with:
#   swift scripts/make_icon.swift /tmp/hootnote-icon && iconutil -c icns /tmp/hootnote-icon/AppIcon.iconset -o Resources/AppIcon.icns
# then re-embed provenance: .claude/skills/impeccable/scripts/impeccable embed-prompt Resources/MenuBarOwl.png --prompt "Origin: drawn in code by scripts/make_icon.swift"
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Hootnote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hootnote "$APP/Contents/MacOS/Hootnote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarOwl.png "$APP/Contents/Resources/"
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# A stable signing identity keeps macOS permissions (mic, system audio, accessibility) across rebuilds.
IDENTITY="${SIGN_IDENTITY:-Whisper Transcription Local Signing}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" --identifier com.local.Hootnote "$APP"
else
    echo "Signing identity \"$IDENTITY\" not found; signing ad-hoc."
    codesign --force --deep --sign - --identifier com.local.Hootnote "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [ "${1:-}" != "--no-install" ]; then
    # Ask the running app to quit (it finishes saving first). Never killed: it may be recording.
    for id in com.local.Hootnote com.local.MeetingScribe; do
        osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    done
    osascript -e 'tell application "Hootnote" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do pgrep -x Hootnote >/dev/null || break; sleep 1; done
    if pgrep -x Hootnote >/dev/null; then
        echo "Hootnote is still running (recording or busy?). Installing anyway; quit and reopen it to load this build."
    fi
    rm -rf /Applications/Hootnote.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Hootnote.app"
    # The app was called MeetingScribe before; move that copy to the Trash (recoverable).
    if [ -d /Applications/MeetingScribe.app ]; then
        mv /Applications/MeetingScribe.app "$HOME/.Trash/MeetingScribe $(date +%Y%m%d-%H%M%S).app" && echo "Moved the old MeetingScribe.app to the Trash"
    fi
fi
