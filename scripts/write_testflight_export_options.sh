#!/bin/bash

set -euo pipefail

output_path="${1:-${EXPORT_OPTIONS_PLIST:-}}"
if [[ -z "$output_path" ]]; then
	echo "usage: $0 EXPORT_OPTIONS_PLIST" >&2
	exit 1
fi

method="${TESTFLIGHT_EXPORT_METHOD:-app-store-connect}"
team_id="${OVERLAY_DEVELOPMENT_TEAM:-}"

if [[ -z "$team_id" ]]; then
	echo "OVERLAY_DEVELOPMENT_TEAM is required" >&2
	exit 1
fi

mkdir -p "$(dirname "$output_path")"
cat > "$output_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF

plistbuddy=/usr/libexec/PlistBuddy
"$plistbuddy" -c "Add :method string $method" "$output_path"
"$plistbuddy" -c "Add :signingStyle string automatic" "$output_path"
"$plistbuddy" -c "Add :teamID string $team_id" "$output_path"
"$plistbuddy" -c "Add :stripSwiftSymbols bool true" "$output_path"
"$plistbuddy" -c "Add :uploadSymbols bool true" "$output_path"
"$plistbuddy" -c "Add :manageAppVersionAndBuildNumber bool false" "$output_path"

plutil -lint "$output_path"
