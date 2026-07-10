#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 SETTING_NAME" >&2
    exit 1
fi

setting_name="$1"

read_setting() {
    config_path="$1"
    if [ ! -f "$config_path" ]; then
        return 1
    fi

    sed -n "s/^${setting_name}[[:space:]]*=[[:space:]]*//p" "$config_path" | tail -n 1
}

for config_path in Config/Overlay.local.xcconfig Config/Overlay.defaults.xcconfig; do
    if setting_value="$(read_setting "$config_path")" && [ -n "$setting_value" ]; then
        printf '%s\n' "$setting_value"
        exit 0
    fi
done

echo "missing overlay setting: $setting_name" >&2
exit 1
