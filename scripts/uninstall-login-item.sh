#!/usr/bin/env bash
set -euo pipefail

agent_path="$HOME/Library/LaunchAgents/net.stupidtech.ProjectsBar.plist"

launchctl unload "$agent_path" 2>/dev/null || true
rm -f "$agent_path"

echo "Removed login item: $agent_path"
