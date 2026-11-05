#!/bin/bash
# Installs AI File Renamer as a macOS background service (launchd user agent).
#   ./install.sh                       # pick folders in a Finder dialog
#   ./install.sh ~/Downloads ~/Desktop # or pass folders directly
set -euo pipefail

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

# 4. launchd agent ------------------------------------------------------------
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
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

# macOS checks the binary that actually runs. Framework builds of Python re-exec
# into Resources/Python.app, so grant access to that app bundle when it exists.
REAL_PY=$("$SUPPORT/venv/bin/python" -c 'import os,sys; print(os.path.realpath(getattr(sys,"_base_executable",sys.executable)))')
APP_PY=$("$SUPPORT/venv/bin/python" -c 'import os,sys; print(os.path.join(sys.base_prefix,"Resources","Python.app"))')
[ -d "$APP_PY" ] && REAL_PY="$APP_PY"
cat <<EOF

AI File Renamer is running.
  Config: $SUPPORT/config.json
  Log:    $LOG   (tail -f "$LOG")

If a watched folder is Downloads, Desktop or Documents, macOS may block the
background service. Grant access in System Settings > Privacy & Security >
Full Disk Access: click +, press Cmd+Shift+G and paste:
  $REAL_PY
Then restart the service:  launchctl kickstart -k gui/$(id -u)/$LABEL
EOF
