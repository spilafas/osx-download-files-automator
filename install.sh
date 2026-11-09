#!/bin/bash
# Installs AI File Renamer as a macOS background service (launchd user agent).
#   ./install.sh                       # pick folders in a Finder dialog
#   ./install.sh ~/Downloads ~/Desktop # or pass folders directly
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this without sudo: ./install.sh"
  echo "The service runs as your user, and macOS folder access can only be turned on in System Settings."
  exit 1
fi

APP="AIFileRenamer"
LABEL="com.github.spilafas.aifilerenamer"
SUPPORT="$HOME/Library/Application Support/$APP"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$APP.log"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# 1. Python environment -------------------------------------------------------
PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] && PY="$c" && break
done
[ -z "$PY" ] && { echo "Python 3 not found. Install Xcode Command Line Tools: xcode-select --install"; exit 1; }
echo "Using $PY ($("$PY" --version))"
[ -x "$SUPPORT/venv/bin/python" ] || "$PY" -m venv "$SUPPORT/venv"
"$SUPPORT/venv/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
"$SUPPORT/venv/bin/python" -m pip install -q -r "$SRC_DIR/requirements.txt"
cp "$SRC_DIR/ai_renamer.py" "$SUPPORT/ai_renamer.py"

# 2. Folders to watch ---------------------------------------------------------
if [ ! -f "$SUPPORT/config.json" ] || [ $# -gt 0 ]; then
  if [ $# -gt 0 ]; then
    FOLDERS=("$@")
  else
    echo "Choose the folder(s) to watch in the dialog..."
    LIST=$(osascript -e 'set fs to choose folder with prompt "Select folder(s) for AI File Renamer to watch" default location (path to downloads folder) with multiple selections allowed
set out to ""
repeat with f in fs
set out to out & POSIX path of f & linefeed
end repeat
return out')
    FOLDERS=()
    while IFS= read -r line; do [ -n "$line" ] && FOLDERS+=("${line%/}"); done <<< "$LIST"
  fi
  "$SUPPORT/venv/bin/python" - "$SRC_DIR/config.example.json" "$SUPPORT/config.json" "${FOLDERS[@]}" <<'PYEOF'
import json, os, sys
example, target, folders = sys.argv[1], sys.argv[2], sys.argv[3:]
cfg = json.load(open(target)) if os.path.exists(target) else json.load(open(example))
cfg["watch_folders"] = [os.path.abspath(os.path.expanduser(f)) for f in folders]
json.dump(cfg, open(target, "w"), indent=2)
print("Watching:", ", ".join(cfg["watch_folders"]))
PYEOF
fi

# 3. API key in the Keychain --------------------------------------------------
if ! security find-generic-password -s ai-file-renamer -a anthropic-api-key >/dev/null 2>&1 || [ "${RESET_KEY:-}" = "1" ]; then
  KEY="${ANTHROPIC_API_KEY:-}"
  if [ -z "$KEY" ]; then
    read -r -s -p "Paste your Anthropic API key (input hidden): " KEY; echo
  fi
  security add-generic-password -U -s ai-file-renamer -a anthropic-api-key -w "$KEY"
  echo "API key saved to your login Keychain."
fi

# 4. App wrapper ------------------------------------------------------------
# macOS only lets you grant Full Disk Access in System Settings (not even root
# can do it from a script). To make that a single switch, the service runs
# inside its own small app, which shows up in the list as "AI File Renamer".
APP_DIR="$HOME/Applications/AI File Renamer.app"
APP_BIN="$APP_DIR/Contents/MacOS/ai-file-renamer"
SRC_HASH=$(shasum -a 256 "$SRC_DIR/launcher.c" | cut -d' ' -f1)
# Rebuild only when the launcher changes: a new build gets a new signature and
# macOS would ask for access again.
if [ "$(cat "$APP_DIR/Contents/Resources/launcher.sha256" 2>/dev/null)" != "$SRC_HASH" ]; then
  echo "Building AI File Renamer.app..."
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  xcrun clang -O2 -o "$APP_BIN" "$SRC_DIR/launcher.c" || {
    echo "Could not compile the launcher. Install the Command Line Tools: xcode-select --install"; exit 1; }
  cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>AI File Renamer</string>
  <key>CFBundleDisplayName</key><string>AI File Renamer</string>
  <key>CFBundleExecutable</key><string>ai-file-renamer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>AI File Renamer renames new files in the folders you chose.</string>
  <key>NSDesktopFolderUsageDescription</key><string>AI File Renamer renames new files in the folders you chose.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>AI File Renamer renames new files in the folders you chose.</string>
</dict>
</plist>
EOF
  echo "$SRC_HASH" > "$APP_DIR/Contents/Resources/launcher.sha256"
  codesign --force --sign - --identifier "$LABEL" "$APP_DIR" >/dev/null 2>&1
fi

# 5. launchd agent ------------------------------------------------------------
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>AssociatedBundleIdentifiers</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BIN</string>
    <string>$SUPPORT/venv/bin/python</string>
    <string>$SUPPORT/ai_renamer.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "AI File Renamer is running."
echo "  Config: $SUPPORT/config.json"
echo "  Log:    $LOG"

# 6. Folder access ------------------------------------------------------------
# Give the service a moment to start, then see whether it can read the folders.
LOG_START=$(wc -l < "$LOG" 2>/dev/null || echo 0)
sleep 4
new_log() { tail -n +"$((LOG_START + 1))" "$LOG" 2>/dev/null; }
if ! new_log | grep -q "No permission to read"; then
  echo "Folder access OK. New files will be renamed automatically."
  exit 0
fi

cat <<EOF

One step left: macOS needs your OK to let the service read the folder.
Opening System Settings > Privacy & Security > Full Disk Access and showing
"AI File Renamer" in Finder:
  1. Drag "AI File Renamer" from the Finder window into the Full Disk Access list
     (or click +, then pick it from your Applications folder in your home folder).
  2. Turn its switch on.

Waiting for access (press Ctrl+C to stop waiting; the service keeps running)...
EOF
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" 2>/dev/null \
  || open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
open -R "$APP_DIR"

for i in $(seq 1 180); do
  sleep 2
  # Some macOS versions only apply a new permission after a restart.
  [ $((i % 10)) -eq 0 ] && launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null
  if new_log | grep -qE "Access to .* granted|Baseline "; then
    echo
    echo "Access granted. AI File Renamer is now watching your folders."
    new_log | grep -E "Baseline " | sed 's/^/  /'
    exit 0
  fi
done
echo
echo "Still no access after 6 minutes. Once you turn it on, the service picks it"
echo "up on its own. Check the log with: tail -f \"$LOG\""
