#!/bin/bash
# Stops and removes the AI File Renamer service. Your files are not touched.
set -uo pipefail
LABEL="com.github.spilafas.aifilerenamer"
SUPPORT="$HOME/Library/Application Support/AIFileRenamer"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Service stopped and removed."

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$SUPPORT"
  security delete-generic-password -s ai-file-renamer -a anthropic-api-key >/dev/null 2>&1
  echo "Config, state, venv and Keychain API key removed."
else
  echo "Config kept in: $SUPPORT  (run ./uninstall.sh --purge to remove it and the API key)"
fi
