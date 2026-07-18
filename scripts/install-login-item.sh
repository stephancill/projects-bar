#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_dir/.build/ProjectsBar.app"
agent_path="$HOME/Library/LaunchAgents/net.stupidtech.ProjectsBar.plist"

if [[ ! -d "$app_path" ]]; then
  "$repo_dir/scripts/build-app.sh"
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$agent_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>net.stupidtech.ProjectsBar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$app_path</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

launchctl unload "$agent_path" 2>/dev/null || true
launchctl load "$agent_path"

echo "Installed login item: $agent_path"
